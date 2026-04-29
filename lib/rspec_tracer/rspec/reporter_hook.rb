# frozen_string_literal: true

module RSpecTracer
  module RSpec
    # Prepended onto `RSpec::Core::Reporter` by
    # `RSpecTracer::RSpec::Installation.install!`. Replaces the 1.x
    # `RSpecTracer::RSpecReporter` singleton-class prepend.
    #
    # Forwards RSpec's example lifecycle notifications into the engine,
    # then chains to `super`. Every callback is no-op when either:
    #   - the engine isn't set up (start never called, graceful degrade)
    #   - the example carries no `:rspec_tracer_example_id` metadata
    #     (it was partitioned into `ignore_spec_files` by RunnerHook, so
    #     the tracer treats it as invisible)
    #
    # The per-example coverage peek+diff sequence (peek before, peek
    # after) runs through Engine#example_started + Engine#example_finished
    # only. M8.0 retired the legacy CoverageReporter that previously
    # peeked a second time per example; coverage.json emission now
    # consumes the Engine's per-example deltas + a single finalize-time
    # peek through Tracker::CoverageAdapter#peek_unfiltered.
    module ReporterHook
      def example_started(_example)
        RSpecTracer.engine&.example_started

        super
      end

      def example_finished(example)
        engine = RSpecTracer.engine
        if engine
          example_id = example.metadata[:rspec_tracer_example_id]
          engine.example_finished(example_id) if example_id
        end

        super
      end

      def example_passed(example)
        _rspec_tracer_status(example, :on_example_passed)

        super
      end

      def example_failed(example)
        _rspec_tracer_status(example, :on_example_failed)

        super
      end

      def example_pending(example)
        _rspec_tracer_status(example, :on_example_pending)

        super
      end

      private

      def _rspec_tracer_status(example, method)
        engine = RSpecTracer.engine
        return unless engine

        example_id = example.metadata[:rspec_tracer_example_id]
        return unless example_id

        engine.public_send(method, example_id, example.execution_result)
      end
    end
  end
end
