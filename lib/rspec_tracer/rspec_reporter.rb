# frozen_string_literal: true

module RSpecTracer
  module RSpecReporter
    def example_started(example)
      RSpecTracer.coverage_reporter.record_coverage
      RSpecTracer.start_example_trace if RSpecTracer.trace_example?

      super(example)
    end

    def example_finished(example)
      RSpecTracer.stop_example_trace(example.pending?) if RSpecTracer.trace_example?

      example_id = example.metadata[:rspec_tracer_example_id]
      RSpecTracer.coverage_reporter.compute_diff(example_id)

      super(example)
    end

    def example_passed(example)
      example_id = example.metadata[:rspec_tracer_example_id]
      RSpecTracer.runner.on_example_passed(example_id, example.execution_result)

      super(example)
    end

    def example_failed(example)
      example_id = example.metadata[:rspec_tracer_example_id]
      RSpecTracer.runner.on_example_failed(example_id, example.execution_result)

      super(example)
    end

    def example_pending(example)
      example_id = example.metadata[:rspec_tracer_example_id]
      RSpecTracer.runner.on_example_pending(example_id, example.execution_result)

      super(example)
    end
  end
end
