# frozen_string_literal: true

module RSpecTracer
  module RSpecRunner
    def run_specs(example_groups)
      actual_count = RSpec.world.example_count

      if _no_examples?(actual_count)
        super(example_groups)

        return
      end

      starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      filtered_examples, filtered_example_groups = RSpecTracer.filter_examples

      if _duplicate_examples?
        super([])

        return
      end

      RSpec.world.instance_variable_set(:@filtered_examples, filtered_examples)
      RSpec.world.instance_variable_set(:@example_groups, filtered_example_groups)

      current_count = RSpec.world.example_count
      ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      elapsed = RSpecTracer::TimeFormatter.format_time(ending - starting)

      RSpecTracer.logger.info <<-EXAMPLES.strip.gsub(/\s+/, ' ')
        RSpec tracer is running #{current_count} examples (actual: #{actual_count},
        skipped: #{actual_count - current_count}) (took #{elapsed})
      EXAMPLES

      RSpecTracer.running = true

      super(filtered_example_groups)
    end

    def _no_examples?(actual_count)
      return false unless actual_count.zero?

      RSpecTracer.running = true
      RSpecTracer.no_examples = true
    end

    def _duplicate_examples?
      return false if RSpecTracer.runner.reporter.duplicate_examples.empty?

      RSpecTracer.report_writer.print_duplicate_examples

      RSpecTracer.running = true
      RSpecTracer.duplicate_examples = RSpecTracer.fail_on_duplicates
    end
  end
end
