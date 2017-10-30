module Sequent
  module Core
    class EventPublisher
      #
      # EventPublisher ensures that, for every thread, events will be published in the order in which they are meant to be published.
      #
      # This potentially introduces a wrinkle into your plans: You therefore should not split a "unit of work" across multiple threads.
      #
      # If you do not want this, you are free to implement your own version of EventPublisher and configure sequent to use it.
      #
      class PublishEventError < RuntimeError
        attr_reader :event_handler_class, :event

        def initialize(event_handler_class, event)
          @event_handler_class = event_handler_class
          @event = event
        end

        def message
          "Event Handler: #{@event_handler_class.inspect}\nEvent: #{@event.inspect}\nCause: #{cause.inspect}"
        end
      end

      def publish_events(events)
        return if configuration.disable_event_handlers
        events.each { |event| events_queue.push(event) }
        process_events
      end

      private

      def events_queue
        Thread.current[:events_queue] ||= Queue.new
      end

      def skip_if_already_processing(&block)
        Thread.current[:events_queue_locked] = false if Thread.current[:events_queue_locked].nil?

        return if Thread.current[:events_queue_locked]

        Thread.current[:events_queue_locked] = true

        block.yield
      ensure
        Thread.current[:events_queue_locked] = false
      end

      def process_events
        skip_if_already_processing do
          while(!events_queue.empty?) do
            event = events_queue.pop
            configuration.event_handlers.each do |handler|
              begin
                handler.handle_message event
              rescue
                raise PublishEventError.new(handler.class, event)
              end
            end
          end
        end
      end

      def configuration
        Sequent.configuration
      end
    end
  end
end
