# frozen_string_literal: true

module RSpecTracer
  module RSpecReporter
    def example_started(example)
      RSpecTracer.coverage_reporter.record_coverage
      if RSpecTracer.v2_engine?
        RSpecTracer.engine.example_started
      else
        RSpecTracer.start_example_trace
      end

      super
    end

    def example_finished(example)
      example_id = example.metadata[:rspec_tracer_example_id]
      if RSpecTracer.v2_engine?
        RSpecTracer.engine.example_finished(example_id)
      else
        RSpecTracer.stop_example_trace(example_id)
      end
      RSpecTracer.coverage_reporter.compute_diff(example_id)

      super
    end

    def example_passed(example)
      example_id = example.metadata[:rspec_tracer_example_id]
      _tracer_status_sink.on_example_passed(example_id, example.execution_result)

      super
    end

    def example_failed(example)
      example_id = example.metadata[:rspec_tracer_example_id]
      _tracer_status_sink.on_example_failed(example_id, example.execution_result)

      super
    end

    def example_pending(example)
      example_id = example.metadata[:rspec_tracer_example_id]
      _tracer_status_sink.on_example_pending(example_id, example.execution_result)

      super
    end

    private

    def _tracer_status_sink
      RSpecTracer.v2_engine? ? RSpecTracer.engine : RSpecTracer.runner
    end
  end
end
