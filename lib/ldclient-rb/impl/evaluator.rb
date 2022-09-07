require "ldclient-rb/evaluation_detail"
require "ldclient-rb/impl/evaluator_bucketing"
require "ldclient-rb/impl/evaluator_helpers"
require "ldclient-rb/impl/evaluator_operators"

module LaunchDarkly
  module Impl
    # Used internally to record that we evaluated a prerequisite flag.
    PrerequisiteEvalRecord = Struct.new(
      :prereq_flag,     # the prerequisite flag that we evaluated
      :prereq_of_flag,  # the flag that it was a prerequisite of
      :detail           # the EvaluationDetail representing the evaluation result
    )

    # Encapsulates the feature flag evaluation logic. The Evaluator has no knowledge of the rest of the SDK environment;
    # if it needs to retrieve flags or segments that are referenced by a flag, it does so through a simple function that
    # is provided in the constructor. It also produces feature requests as appropriate for any referenced prerequisite
    # flags, but does not send them.
    class Evaluator
      # A single Evaluator is instantiated for each client instance.
      #
      # @param get_flag [Function] called if the Evaluator needs to query a different flag from the one that it is
      #   currently evaluating (i.e. a prerequisite flag); takes a single parameter, the flag key, and returns the
      #   flag data - or nil if the flag is unknown or deleted
      # @param get_segment [Function] similar to `get_flag`, but is used to query a user segment.
      # @param logger [Logger] the client's logger
      def initialize(get_flag, get_segment, get_big_segments_membership, logger)
        @get_flag = get_flag
        @get_segment = get_segment
        @get_big_segments_membership = get_big_segments_membership
        @logger = logger
      end
  
      # Used internally to hold an evaluation result and additional state that may be accumulated during an
      # evaluation. It's simpler and a bit more efficient to represent these as mutable properties rather than
      # trying to use a pure functional approach, and since we're not exposing this object to any application code
      # or retaining it anywhere, we don't have to be quite as strict about immutability.
      #
      # The big_segments_status and big_segments_membership properties are not used by the caller; they are used
      # during an evaluation to cache the result of any Big Segments query that we've done for this user, because
      # we don't want to do multiple queries for the same user if multiple Big Segments are referenced in the same
      # evaluation.
      EvalResult = Struct.new(
        :detail,  # the EvaluationDetail representing the evaluation result
        :prereq_evals,  # an array of PrerequisiteEvalRecord instances, or nil
        :big_segments_status,
        :big_segments_membership
      )

      # Helper function used internally to construct an EvaluationDetail for an error result.
      def self.error_result(errorKind, value = nil)
        EvaluationDetail.new(value, nil, EvaluationReason.error(errorKind))
      end

      # The client's entry point for evaluating a flag. The returned `EvalResult` contains the evaluation result and
      # any events that were generated for prerequisite flags; its `value` will be `nil` if the flag returns the
      # default value. Error conditions produce a result with a nil value and an error reason, not an exception.
      #
      # @param flag [Object] the flag
      # @param user [Object] the user properties
      # @return [EvalResult] the evaluation result 
      def evaluate(flag, user)
        result = EvalResult.new
        if user.nil? || user[:key].nil?
          result.detail = Evaluator.error_result(EvaluationReason::ERROR_USER_NOT_SPECIFIED)
          return result
        end
        
        detail = eval_internal(flag, user, result)
        if !result.big_segments_status.nil?
          # If big_segments_status is non-nil at the end of the evaluation, it means a query was done at
          # some point and we will want to include the status in the evaluation reason.
          detail = EvaluationDetail.new(detail.value, detail.variation_index,
            detail.reason.with_big_segments_status(result.big_segments_status))
        end
        result.detail = detail
        return result
      end

      def self.make_big_segment_ref(segment)  # method is visible for testing
        # The format of Big Segment references is independent of what store implementation is being
        # used; the store implementation receives only this string and does not know the details of
        # the data model. The Relay Proxy will use the same format when writing to the store.
        "#{segment[:key]}.g#{segment[:generation]}"
      end

      private
      
      def eval_internal(flag, user, state)
        if !flag[:on]
          return EvaluatorHelpers.off_result(flag)
        end

        prereq_failure_result = check_prerequisites(flag, user, state)
        return prereq_failure_result if !prereq_failure_result.nil?

        # Check user target matches
        (flag[:targets] || []).each do |target|
          (target[:values] || []).each do |value|
            if value == user[:key]
              return EvaluatorHelpers.target_match_result(target, flag)
            end
          end
        end
      
        # Check custom rules
        rules = flag[:rules] || []
        rules.each_index do |i|
          rule = rules[i]
          if rule_match_user(rule, user, state)
            reason = rule[:_reason]  # try to use cached reason for this rule
            reason = EvaluationReason::rule_match(i, rule[:id]) if reason.nil?
            return get_value_for_variation_or_rollout(flag, rule, user, reason,
              EvaluatorHelpers.rule_precomputed_results(rule))
          end
        end

        # Check the fallthrough rule
        if !flag[:fallthrough].nil?
          return get_value_for_variation_or_rollout(flag, flag[:fallthrough], user, EvaluationReason::fallthrough,
            EvaluatorHelpers.fallthrough_precomputed_results(flag))
        end

        return EvaluationDetail.new(nil, nil, EvaluationReason::fallthrough)
      end

      def check_prerequisites(flag, user, state)
        (flag[:prerequisites] || []).each do |prerequisite|
          prereq_ok = true
          prereq_key = prerequisite[:key]
          prereq_flag = @get_flag.call(prereq_key)

          if prereq_flag.nil?
            @logger.error { "[LDClient] Could not retrieve prerequisite flag \"#{prereq_key}\" when evaluating \"#{flag[:key]}\"" }
            prereq_ok = false
          else
            begin
              prereq_res = eval_internal(prereq_flag, user, state)
              # Note that if the prerequisite flag is off, we don't consider it a match no matter what its
              # off variation was. But we still need to evaluate it in order to generate an event.
              if !prereq_flag[:on] || prereq_res.variation_index != prerequisite[:variation]
                prereq_ok = false
              end
              prereq_eval = PrerequisiteEvalRecord.new(prereq_flag, flag, prereq_res)
              state.prereq_evals = [] if state.prereq_evals.nil?
              state.prereq_evals.push(prereq_eval)
            rescue => exn
              Util.log_exception(@logger, "Error evaluating prerequisite flag \"#{prereq_key}\" for flag \"#{flag[:key]}\"", exn)
              prereq_ok = false
            end
          end
          if !prereq_ok
            return EvaluatorHelpers.prerequisite_failed_result(prerequisite, flag)
          end
        end
        nil
      end

      def rule_match_user(rule, user, state)
        return false if !rule[:clauses]

        (rule[:clauses] || []).each do |clause|
          return false if !clause_match_user(clause, user, state)
        end

        return true
      end

      def clause_match_user(clause, user, state)
        # In the case of a segment match operator, we check if the user is in any of the segments,
        # and possibly negate
        if clause[:op].to_sym == :segmentMatch
          result = (clause[:values] || []).any? { |v|
            segment = @get_segment.call(v)
            !segment.nil? && segment_match_user(segment, user, state)
          }
          clause[:negate] ? !result : result
        else
          clause_match_user_no_segments(clause, user)
        end
      end

      def clause_match_user_no_segments(clause, user)
        user_val = EvaluatorOperators.user_value(user, clause[:attribute])
        return false if user_val.nil?

        op = clause[:op].to_sym
        clause_vals = clause[:values]
        result = if user_val.is_a? Enumerable
          user_val.any? { |uv| clause_vals.any? { |cv| EvaluatorOperators.apply(op, uv, cv) } }
        else
          clause_vals.any? { |cv| EvaluatorOperators.apply(op, user_val, cv) }
        end
        clause[:negate] ? !result : result
      end

      def segment_match_user(segment, user, state)
        return false unless user[:key]
        segment[:unbounded] ? big_segment_match_user(segment, user, state) : simple_segment_match_user(segment, user, true)
      end

      def big_segment_match_user(segment, user, state)
        if !segment[:generation]
          # Big segment queries can only be done if the generation is known. If it's unset,
          # that probably means the data store was populated by an older SDK that doesn't know
          # about the generation property and therefore dropped it from the JSON data. We'll treat
          # that as a "not configured" condition.
          state.big_segments_status = BigSegmentsStatus::NOT_CONFIGURED
          return false
        end
        if !state.big_segments_status
          result = @get_big_segments_membership.nil? ? nil : @get_big_segments_membership.call(user[:key])
          if result
            state.big_segments_membership = result.membership
            state.big_segments_status = result.status
          else
            state.big_segments_membership = nil
            state.big_segments_status = BigSegmentsStatus::NOT_CONFIGURED
          end
        end
        segment_ref = Evaluator.make_big_segment_ref(segment)
        membership = state.big_segments_membership
        included = membership.nil? ? nil : membership[segment_ref]
        return included if !included.nil?
        simple_segment_match_user(segment, user, false)
      end

      def simple_segment_match_user(segment, user, use_includes_and_excludes)
        if use_includes_and_excludes
          return true if segment[:included].include?(user[:key])
          return false if segment[:excluded].include?(user[:key])
        end

        (segment[:rules] || []).each do |r|
          return true if segment_rule_match_user(r, user, segment[:key], segment[:salt])
        end

        return false
      end

      def segment_rule_match_user(rule, user, segment_key, salt)
        (rule[:clauses] || []).each do |c|
          return false unless clause_match_user_no_segments(c, user)
        end

        # If the weight is absent, this rule matches
        return true if !rule[:weight]
        
        # All of the clauses are met. See if the user buckets in
        bucket = EvaluatorBucketing.bucket_user(user, segment_key, rule[:bucketBy].nil? ? "key" : rule[:bucketBy], salt, nil)
        weight = rule[:weight].to_f / 100000.0
        return bucket < weight
      end

      private
      
      def get_value_for_variation_or_rollout(flag, vr, user, reason, precomputed_results)
        index, in_experiment = EvaluatorBucketing.variation_index_for_user(flag, vr, user)
        if index.nil?
          @logger.error("[LDClient] Data inconsistency in feature flag \"#{flag[:key]}\": variation/rollout object with no variation or rollout")
          return Evaluator.error_result(EvaluationReason::ERROR_MALFORMED_FLAG)
        end
        if precomputed_results
          return precomputed_results.for_variation(index, in_experiment)
        else
          #if in experiment is true, set reason to a different reason instance/singleton with in_experiment set
          if in_experiment
            if reason.kind == :FALLTHROUGH
              reason = EvaluationReason::fallthrough(in_experiment)
            elsif reason.kind == :RULE_MATCH
              reason = EvaluationReason::rule_match(reason.rule_index, reason.rule_id, in_experiment)
            end
          end
          return EvaluatorHelpers.evaluation_detail_for_variation(flag, index, reason)
        end
      end
    end
  end
end
