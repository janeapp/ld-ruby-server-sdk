require "ldclient-rb/impl/diagnostic_events"
require "ldclient-rb/impl/event_sender"
require "ldclient-rb/impl/event_summarizer"
require "ldclient-rb/impl/event_types"
require "ldclient-rb/impl/util"

require "concurrent"
require "concurrent/atomics"
require "concurrent/executors"
require "thread"
require "time"

#
# Analytics event processing in the SDK involves several components. The purpose of this design is to
# minimize overhead on the application threads that are generating analytics events.
#
# EventProcessor receives an analytics event from the SDK client, on an application thread. It places
# the event in a bounded queue, the "inbox", and immediately returns.
#
# On a separate worker thread, EventDispatcher consumes events from the inbox. These are considered
# "input events" because they may or may not actually be sent to LaunchDarkly; most flag evaluation
# events are not sent, but are counted and the counters become part of a single summary event.
# EventDispatcher updates those counters, creates "index" events for any users that have not been seen
# recently, and places any events that will be sent to LaunchDarkly into the "outbox" queue.
#
# When it is time to flush events to LaunchDarkly, the contents of the outbox are handed off to
# another worker thread which sends the HTTP request.
#

module LaunchDarkly
  module EventProcessorMethods
    def record_eval_event(
      user,
      key,
      version = nil,
      variation = nil,
      value = nil,
      reason = nil,
      default = nil,
      track_events = false,
      debug_until = nil,
      prereq_of = nil
    )
    end

    def record_identify_event(user)
    end

    def record_custom_event(
      user,
      key,
      data = nil,
      metric_value = nil
    )
    end

    def record_alias_event(user, previous_user)
    end

    def flush
    end

    def stop
    end
  end

  MAX_FLUSH_WORKERS = 5
  USER_ATTRS_TO_STRINGIFY_FOR_EVENTS = [ :key, :secondary, :ip, :country, :email, :firstName, :lastName,
    :avatar, :name ]

  private_constant :MAX_FLUSH_WORKERS
  private_constant :USER_ATTRS_TO_STRINGIFY_FOR_EVENTS

  # @private
  class NullEventProcessor
    include EventProcessorMethods
  end

  # @private
  class FlushMessage
  end

  # @private
  class FlushUsersMessage
  end

  # @private
  class DiagnosticEventMessage
  end

  # @private
  class SynchronousMessage
    def initialize
      @reply = Concurrent::Semaphore.new(0)
    end
    
    def completed
      @reply.release
    end

    def wait_for_completion
      @reply.acquire
    end
  end

  # @private
  class TestSyncMessage < SynchronousMessage
  end

  # @private
  class StopMessage < SynchronousMessage
  end

  # @private
  class EventProcessor
    include EventProcessorMethods

    def initialize(sdk_key, config, client = nil, diagnostic_accumulator = nil, test_properties = nil)
      raise ArgumentError, "sdk_key must not be nil" if sdk_key.nil?  # see LDClient constructor comment on sdk_key
      @logger = config.logger
      @inbox = SizedQueue.new(config.capacity < 100 ? 100 : config.capacity)
      @flush_task = Concurrent::TimerTask.new(execution_interval: config.flush_interval) do
        post_to_inbox(FlushMessage.new)
      end
      @flush_task.execute
      @users_flush_task = Concurrent::TimerTask.new(execution_interval: config.user_keys_flush_interval) do
        post_to_inbox(FlushUsersMessage.new)
      end
      @users_flush_task.execute
      if !diagnostic_accumulator.nil?
        interval = test_properties && test_properties.has_key?(:diagnostic_recording_interval) ?
          test_properties[:diagnostic_recording_interval] :
          config.diagnostic_recording_interval
        @diagnostic_event_task = Concurrent::TimerTask.new(execution_interval: interval) do
          post_to_inbox(DiagnosticEventMessage.new)
        end
        @diagnostic_event_task.execute
      else
        @diagnostic_event_task = nil
      end
      @stopped = Concurrent::AtomicBoolean.new(false)
      @inbox_full = Concurrent::AtomicBoolean.new(false)

      event_sender = (test_properties || {})[:event_sender] ||
        Impl::EventSender.new(sdk_key, config, client ? client : Util.new_http_client(config.events_uri, config))

      @timestamp_fn = (test_properties || {})[:timestamp_fn] || proc { Impl::Util.current_time_millis }

      EventDispatcher.new(@inbox, sdk_key, config, diagnostic_accumulator, event_sender)
    end

    def record_eval_event(
      user,
      key,
      version = nil,
      variation = nil,
      value = nil,
      reason = nil,
      default = nil,
      track_events = false,
      debug_until = nil,
      prereq_of = nil
    )
      post_to_inbox(LaunchDarkly::Impl::EvalEvent.new(timestamp, user, key, version, variation, value, reason,
        default, track_events, debug_until, prereq_of))
    end

    def record_identify_event(user)
      post_to_inbox(LaunchDarkly::Impl::IdentifyEvent.new(timestamp, user))
    end

    def record_custom_event(user, key, data = nil, metric_value = nil)
      post_to_inbox(LaunchDarkly::Impl::CustomEvent.new(timestamp, user, key, data, metric_value))
    end

    def record_alias_event(user, previous_user)
      post_to_inbox(LaunchDarkly::Impl::AliasEvent.new(
        timestamp,
        user.nil? ? nil : user[:key],
        user_to_context_kind(user),
        previous_user.nil? ? nil : previous_user[:key],
        user_to_context_kind(previous_user)
      ))
    end

    def flush
      # flush is done asynchronously
      post_to_inbox(FlushMessage.new)
    end

    def stop
      # final shutdown, which includes a final flush, is done synchronously
      if @stopped.make_true
        @flush_task.shutdown
        @users_flush_task.shutdown
        @diagnostic_event_task.shutdown if !@diagnostic_event_task.nil?
        # Note that here we are not calling post_to_inbox, because we *do* want to wait if the inbox
        # is full; an orderly shutdown can't happen unless these messages are received.
        @inbox << FlushMessage.new
        stop_msg = StopMessage.new
        @inbox << stop_msg
        stop_msg.wait_for_completion
      end
    end

    # exposed only for testing
    def wait_until_inactive
      sync_msg = TestSyncMessage.new
      @inbox << sync_msg
      sync_msg.wait_for_completion
    end

    private def timestamp
      @timestamp_fn.call()
    end

    private def post_to_inbox(message)
      begin
        @inbox.push(message, non_block=true)
      rescue ThreadError
        # If the inbox is full, it means the EventDispatcher thread is seriously backed up with not-yet-processed
        # events. This is unlikely, but if it happens, it means the application is probably doing a ton of flag
        # evaluations across many threads-- so if we wait for a space in the inbox, we risk a very serious slowdown
        # of the app. To avoid that, we'll just drop the event. The log warning about this will only be shown once.
        if @inbox_full.make_true
          @logger.warn { "[LDClient] Events are being produced faster than they can be processed; some events will be dropped" }
        end
      end
    end

    private def user_to_context_kind(user)
      (user.nil? || !user[:anonymous]) ? 'user' : 'anonymousUser'
    end
  end

  # @private
  class EventDispatcher
    def initialize(inbox, sdk_key, config, diagnostic_accumulator, event_sender)
      @sdk_key = sdk_key
      @config = config
      @diagnostic_accumulator = config.diagnostic_opt_out? ? nil : diagnostic_accumulator
      @event_sender = event_sender

      @user_keys = SimpleLRUCacheSet.new(config.user_keys_capacity)
      @formatter = EventOutputFormatter.new(config)
      @disabled = Concurrent::AtomicBoolean.new(false)
      @last_known_past_time = Concurrent::AtomicReference.new(0)
      @deduplicated_users = 0
      @events_in_last_batch = 0
      
      outbox = EventBuffer.new(config.capacity, config.logger)
      flush_workers = NonBlockingThreadPool.new(MAX_FLUSH_WORKERS)

      if !@diagnostic_accumulator.nil?
        diagnostic_event_workers = NonBlockingThreadPool.new(1)
        init_event = @diagnostic_accumulator.create_init_event(config)
        send_diagnostic_event(init_event, diagnostic_event_workers)
      else
        diagnostic_event_workers = nil
      end

      Thread.new { main_loop(inbox, outbox, flush_workers, diagnostic_event_workers) }
    end

    private

    def main_loop(inbox, outbox, flush_workers, diagnostic_event_workers)
      running = true
      while running do
        begin
          message = inbox.pop
          case message
          when FlushMessage
            trigger_flush(outbox, flush_workers)
          when FlushUsersMessage
            @user_keys.clear
          when DiagnosticEventMessage
            send_and_reset_diagnostics(outbox, diagnostic_event_workers)
          when TestSyncMessage
            synchronize_for_testing(flush_workers, diagnostic_event_workers)
            message.completed
          when StopMessage
            do_shutdown(flush_workers, diagnostic_event_workers)
            running = false
            message.completed
          else
            dispatch_event(message, outbox)
          end
        rescue => e
          Util.log_exception(@config.logger, "Unexpected error in event processor", e)
        end
      end
    end

    def do_shutdown(flush_workers, diagnostic_event_workers)
      flush_workers.shutdown
      flush_workers.wait_for_termination
      if !diagnostic_event_workers.nil?
        diagnostic_event_workers.shutdown
        diagnostic_event_workers.wait_for_termination
      end
      @event_sender.stop if @event_sender.respond_to?(:stop)
    end

    def synchronize_for_testing(flush_workers, diagnostic_event_workers)
      # Used only by unit tests. Wait until all active flush workers have finished.
      flush_workers.wait_all
      diagnostic_event_workers.wait_all if !diagnostic_event_workers.nil?
    end

    def dispatch_event(event, outbox)
      return if @disabled.value

      # Always record the event in the summary.
      outbox.add_to_summary(event)

      # Decide whether to add the event to the payload. Feature events may be added twice, once for
      # the event (if tracked) and once for debugging.
      will_add_full_event = false
      debug_event = nil
      if event.is_a?(LaunchDarkly::Impl::EvalEvent)
        will_add_full_event = event.track_events
        if should_debug_event(event)
          debug_event = LaunchDarkly::Impl::DebugEvent.new(event)
        end
      else
        will_add_full_event = true
      end

      # For each user we haven't seen before, we add an index event - unless this is already
      # an identify event for that user.
      if !(will_add_full_event && @config.inline_users_in_events)
        if !event.user.nil? && !notice_user(event.user) && !event.is_a?(LaunchDarkly::Impl::IdentifyEvent)
          outbox.add_event(LaunchDarkly::Impl::IndexEvent.new(event.timestamp, event.user))
        end
      end

      outbox.add_event(event) if will_add_full_event
      outbox.add_event(debug_event) if !debug_event.nil?
    end

    # Add to the set of users we've noticed, and return true if the user was already known to us.
    def notice_user(user)
      if user.nil? || !user.has_key?(:key)
        true
      else
        known = @user_keys.add(user[:key].to_s)
        @deduplicated_users += 1 if known
        known
      end
    end

    def should_debug_event(event)
      debug_until = event.debug_until
      if !debug_until.nil?
        last_past = @last_known_past_time.value
        debug_until > last_past && debug_until > Impl::Util.current_time_millis
      else
        false
      end
    end

    def trigger_flush(outbox, flush_workers)
      if @disabled.value
        return
      end

      payload = outbox.get_payload  
      if !payload.events.empty? || !payload.summary.counters.empty?
        count = payload.events.length + (payload.summary.counters.empty? ? 0 : 1)
        @events_in_last_batch = count
        # If all available worker threads are busy, success will be false and no job will be queued.
        success = flush_workers.post do
          begin
            events_out = @formatter.make_output_events(payload.events, payload.summary)
            result = @event_sender.send_event_data(events_out.to_json, "#{events_out.length} events", false)
            @disabled.value = true if result.must_shutdown
            if !result.time_from_server.nil?
              @last_known_past_time.value = (result.time_from_server.to_f * 1000).to_i
            end
          rescue => e
            Util.log_exception(@config.logger, "Unexpected error in event processor", e)
          end
        end
        outbox.clear if success # Reset our internal state, these events now belong to the flush worker
      else
        @events_in_last_batch = 0
      end
    end

    def send_and_reset_diagnostics(outbox, diagnostic_event_workers)
      return if @diagnostic_accumulator.nil?
      dropped_count = outbox.get_and_clear_dropped_count
      event = @diagnostic_accumulator.create_periodic_event_and_reset(dropped_count, @deduplicated_users, @events_in_last_batch)
      @deduplicated_users = 0
      @events_in_last_batch = 0
      send_diagnostic_event(event, diagnostic_event_workers)
    end

    def send_diagnostic_event(event, diagnostic_event_workers)
      return if diagnostic_event_workers.nil?
      uri = URI(@config.events_uri + "/diagnostic")
      diagnostic_event_workers.post do
        begin
          @event_sender.send_event_data(event.to_json, "diagnostic event", true)
        rescue => e
          Util.log_exception(@config.logger, "Unexpected error in event processor", e)
        end
      end
    end
  end

  # @private
  FlushPayload = Struct.new(:events, :summary)

  # @private
  class EventBuffer
    def initialize(capacity, logger)
      @capacity = capacity
      @logger = logger
      @capacity_exceeded = false
      @dropped_events = 0
      @events = []
      @summarizer = LaunchDarkly::Impl::EventSummarizer.new
    end

    def add_event(event)
      if @events.length < @capacity
        @events.push(event)
        @capacity_exceeded = false
      else
        @dropped_events += 1
        if !@capacity_exceeded
          @capacity_exceeded = true
          @logger.warn { "[LDClient] Exceeded event queue capacity. Increase capacity to avoid dropping events." }
        end
      end
    end

    def add_to_summary(event)
      @summarizer.summarize_event(event)
    end

    def get_payload
      return FlushPayload.new(@events, @summarizer.snapshot)
    end

    def get_and_clear_dropped_count
      ret = @dropped_events
      @dropped_events = 0
      ret
    end

    def clear
      @events = []
      @summarizer.clear
    end
  end

  # @private
  class EventOutputFormatter
    FEATURE_KIND = 'feature'
    IDENTIFY_KIND = 'identify'
    CUSTOM_KIND = 'custom'
    ALIAS_KIND = 'alias'
    INDEX_KIND = 'index'
    DEBUG_KIND = 'debug'
    SUMMARY_KIND = 'summary'
    ANONYMOUS_USER_CONTEXT_KIND = 'anonymousUser'

    def initialize(config)
      @inline_users = config.inline_users_in_events
      @user_filter = UserFilter.new(config)
    end

    # Transforms events into the format used for event sending.
    def make_output_events(events, summary)
      events_out = events.map { |e| make_output_event(e) }
      if !summary.counters.empty?
        events_out.push(make_summary_event(summary))
      end
      events_out
    end

    private def make_output_event(event)
      case event
        
      when LaunchDarkly::Impl::EvalEvent
        out = {
          kind: FEATURE_KIND,
          creationDate: event.timestamp,
          key: event.key,
          value: event.value
        }
        out[:default] = event.default if !event.default.nil?
        out[:variation] = event.variation if !event.variation.nil?
        out[:version] = event.version if !event.version.nil?
        out[:prereqOf] = event.prereq_of if !event.prereq_of.nil?
        set_opt_context_kind(out, event.user)
        set_user_or_user_key(out, event.user)
        out[:reason] = event.reason if !event.reason.nil?
        out

      when LaunchDarkly::Impl::IdentifyEvent
        {
          kind: IDENTIFY_KIND,
          creationDate: event.timestamp,
          key: event.user[:key].to_s,
          user: process_user(event.user)
        }
      
      when LaunchDarkly::Impl::CustomEvent
        out = {
          kind: CUSTOM_KIND,
          creationDate: event.timestamp,
          key: event.key
        }
        out[:data] = event.data if !event.data.nil?
        set_user_or_user_key(out, event.user)
        out[:metricValue] = event.metric_value if !event.metric_value.nil?
        set_opt_context_kind(out, event.user)
        out

      when LaunchDarkly::Impl::AliasEvent
        {
          kind: ALIAS_KIND,
          creationDate: event.timestamp,
          key: event.key,
          contextKind: event.context_kind,
          previousKey: event.previous_key,
          previousContextKind: event.previous_context_kind
        }
      
      when LaunchDarkly::Impl::IndexEvent
        {
          kind: INDEX_KIND,
          creationDate: event.timestamp,
          user: process_user(event.user)
        }
      
      when LaunchDarkly::Impl::DebugEvent
        original = event.eval_event
        out = {
          kind: DEBUG_KIND,
          creationDate: original.timestamp,
          key: original.key,
          user: process_user(original.user),
          value: original.value
        }
        out[:default] = original.default if !original.default.nil?
        out[:variation] = original.variation if !original.variation.nil?
        out[:version] = original.version if !original.version.nil?
        out[:prereqOf] = original.prereq_of if !original.prereq_of.nil?
        set_opt_context_kind(out, original.user)
        out[:reason] = original.reason if !original.reason.nil?
        out

      else
        nil
      end
    end

    # Transforms the summary data into the format used for event sending.
    private def make_summary_event(summary)
      flags = {}
      summary.counters.each do |flagKey, flagInfo|
        counters = []
        flagInfo.versions.each do |version, variations|
          variations.each do |variation, counter|
            c = {
              value: counter.value,
              count: counter.count
            }
            c[:variation] = variation if !variation.nil?
            if version.nil?
              c[:unknown] = true
            else
              c[:version] = version
            end
            counters.push(c)
          end
        end
        flags[flagKey] = { default: flagInfo.default, counters: counters }
      end
      {
        kind: SUMMARY_KIND,
        startDate: summary[:start_date],
        endDate: summary[:end_date],
        features: flags
      }
    end

    private def set_opt_context_kind(out, user)
      out[:contextKind] = ANONYMOUS_USER_CONTEXT_KIND if !user.nil? && user[:anonymous]
    end

    private def set_user_or_user_key(out, user)
      if @inline_users
        out[:user] = process_user(user)
      else
        key = user[:key]
        out[:userKey] = key.is_a?(String) ? key : key.to_s
      end
    end

    private def process_user(user)
      filtered = @user_filter.transform_user_props(user)
      Util.stringify_attrs(filtered, USER_ATTRS_TO_STRINGIFY_FOR_EVENTS)
    end
  end
end
