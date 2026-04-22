# frozen_string_literal: true

module RSpecTracer
  module RSpec
    # Prepended onto `RSpec::Core::Reporter` by
    # `RSpecTracer::RSpec::Installation.install!`. Replaces the 1.x
    # `RSpecTracer::RSpecReporter` singleton-class prepend.
    #
    # Forwards RSpec's example lifecycle notifications into the engine
    # and the coverage_reporter, then chains to `super`. Every callback
    # is no-op when either:
    #   - the engine isn't set up (start never called, graceful degrade)
    #   - the example carries no `:rspec_tracer_example_id` metadata
    #     (it was partitioned into `ignore_spec_files` by RunnerHook, so
    #     the tracer treats it as invisible)
    #
    # The per-example coverage peek+diff sequence (peek before, peek
    # after) runs through CoverageReporter for coverage.json parity with
    # 1.x and through Engine for dependency attribution. Two peeks per
    # example costs microseconds; the double attribution was M3.6's
    # deliberate "keep coverage.json emission on the legacy path" call.
    module ReporterHook
      def example_started(example)
        engine = RSpecTracer.engine
        if engine
          RSpecTracer.coverage_reporter&.record_coverage
          engine.example_started
        end

        super
      end

      def example_finished(example)
        engine = RSpecTracer.engine
        if engine
          example_id = example.metadata[:rspec_tracer_example_id]
          if example_id
            engine.example_finished(example_id)
            RSpecTracer.coverage_reporter&.compute_diff(example_id)
          end
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
