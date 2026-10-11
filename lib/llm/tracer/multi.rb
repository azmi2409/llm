# frozen_string_literal: true

module LLM
  class Tracer
    ##
    # A tracer that fans out every tracing callback to a set of
    # tracers, so a request can (for example) be logged to a file
    # and exported to OpenTelemetry at the same time.
    #
    # Spans returned by {on_request_start} and {on_tool_start} are
    # tracked per tracer, and each tracer is handed back the span
    # it returned when the request or tool finishes, errors, or is
    # interrupted.
    #
    # A tracer that raises does not take the others down with it:
    # the error is reported the same way
    # {LLM::Tracer::Rescue LLM::Tracer::Rescue} reports a crashed
    # tracer, and the remaining tracers still run.
    #
    # @example
    #   LLM::Tracer::Multi.new(
    #     LLM::Tracer.logger(llm, io: $stdout),
    #     LLM::Tracer.telemetry(llm)
    #   )
    class Multi < Tracer
      ##
      # The spans one start callback produced, keyed by tracer.
      # Passed back to {#on_request_finish}, {#on_request_error},
      # {#on_tool_finish}, {#on_tool_interrupt}, {#on_tool_error},
      # and {#on_interrupt} as the `span:` argument.
      # @api private
      class Spans
        ##
        # @param [Hash] spans
        #  A map of tracer to the span it returned
        def initialize(spans = {})
          @spans = spans
        end

        ##
        # @param [LLM::Tracer] tracer
        # @return [Object, nil]
        #  The span the tracer returned from the start callback,
        #  or nil when it returned none
        def for(tracer)
          @spans[tracer]
        end
      end

      ##
      # @return [Array<LLM::Tracer>]
      #  The tracers callbacks are fanned out to
      attr_reader :tracers

      ##
      # @param [Array<LLM::Tracer>] tracers
      #  The tracers to fan out to
      def initialize(*tracers)
        super(tracers.first&.llm)
        @tracers = tracers
      end

      ##
      # @param (see LLM::Tracer#on_request_start)
      # @return [LLM::Tracer::Multi::Spans]
      #  The spans each tracer returned, keyed by tracer
      def on_request_start(operation:, model: nil, inputs: nil, request_id:)
        Spans.new(
          @tracers.to_h do |tracer|
            [tracer, safely(tracer) do
              tracer.on_request_start(operation:, model:, inputs:, request_id:)
            end]
          end
        )
      end

      ##
      # @param (see LLM::Tracer#on_request_finish)
      # @return [nil]
      def on_request_finish(operation:, res:, model: nil, span: nil, outputs: nil, metadata: nil, request_id:)
        spans = unwrap(span)
        each_tracer do |tracer|
          tracer.on_request_finish(
            operation:, res:, model:, span: spans.for(tracer),
            outputs:, metadata:, request_id:
          )
        end
        nil
      end

      ##
      # @param (see LLM::Tracer#on_request_error)
      # @return [nil]
      def on_request_error(ex:, span:, request_id:)
        spans = unwrap(span)
        each_tracer do |tracer|
          tracer.on_request_error(ex:, span: spans.for(tracer), request_id:)
        end
        nil
      end

      ##
      # @param (see LLM::Tracer#on_tool_start)
      # @return [LLM::Tracer::Multi::Spans]
      #  The spans each tracer returned, keyed by tracer
      def on_tool_start(id:, name:, arguments:, model:)
        Spans.new(
          @tracers.to_h do |tracer|
            [tracer, safely(tracer) do
              tracer.on_tool_start(id:, name:, arguments:, model:)
            end]
          end
        )
      end

      ##
      # @param (see LLM::Tracer#on_tool_interrupt)
      # @return [nil]
      def on_tool_interrupt(ex:, span:)
        spans = unwrap(span)
        each_tracer do |tracer|
          tracer.on_tool_interrupt(ex:, span: spans.for(tracer))
        end
        nil
      end

      ##
      # @param (see LLM::Tracer#on_tool_finish)
      # @return [nil]
      def on_tool_finish(result:, span:)
        spans = unwrap(span)
        each_tracer do |tracer|
          tracer.on_tool_finish(result:, span: spans.for(tracer))
        end
        nil
      end

      ##
      # @param (see LLM::Tracer#on_tool_error)
      # @return [nil]
      def on_tool_error(ex:, span:)
        spans = unwrap(span)
        each_tracer do |tracer|
          tracer.on_tool_error(ex:, span: spans.for(tracer))
        end
        nil
      end

      ##
      # @param (see LLM::Tracer#on_interrupt)
      # @return [nil]
      def on_interrupt(scope:, span: nil, request_id: nil)
        spans = unwrap(span)
        each_tracer do |tracer|
          tracer.on_interrupt(scope:, span: spans.for(tracer), request_id:)
        end
        nil
      end

      ##
      # @return [nil]
      def on_exit
        each_tracer(&:on_exit)
        nil
      end

      ##
      # @param (see LLM::Tracer#start_trace)
      # @return [self]
      def start_trace(trace_group_id: nil, name: "llm", attributes: {}, metadata: nil)
        each_tracer { |tracer| tracer.start_trace(trace_group_id:, name:, attributes:, metadata:) }
        self
      end

      ##
      # @return [self]
      def stop_trace
        each_tracer(&:stop_trace)
        self
      end

      ##
      # @param (see LLM::Tracer#set_finish_metadata_proc)
      # @return [self]
      def set_finish_metadata_proc(proc)
        each_tracer { |tracer| tracer.set_finish_metadata_proc(proc) }
        self
      end

      ##
      # @param (see LLM::Tracer#merge_extra)
      # @return [self]
      def merge_extra(metadata: nil, inputs: nil, outputs: nil)
        each_tracer { |tracer| tracer.merge_extra(metadata:, inputs:, outputs:) }
        self
      end

      ##
      # @return [Array]
      #  The spans of every tracer, in tracer order
      def spans
        @tracers.flat_map(&:spans)
      end

      ##
      # @return [nil]
      def flush!
        each_tracer(&:flush!)
        nil
      end

      private

      ##
      # @param [Object, nil] span
      # @return [LLM::Tracer::Multi::Spans]
      def unwrap(span)
        span.is_a?(Spans) ? span : Spans.new
      end

      def each_tracer
        @tracers.each { |tracer| safely(tracer) { yield tracer } }
      end

      ##
      # Runs one callback against one tracer. A StandardError (or
      # ScriptError) is reported the way
      # {LLM::Tracer::Rescue LLM::Tracer::Rescue} reports a crashed
      # tracer, so the remaining tracers still run. An
      # {LLM::Interrupt LLM::Interrupt} travels up the stack, like
      # everywhere else in the gem.
      def safely(tracer)
        yield
      rescue LLM::Interrupt
        raise
      rescue StandardError, ScriptError => ex
        LLM::Tracer::Rescue.crash(tracer, ex)
        nil
      end
    end
  end
end
