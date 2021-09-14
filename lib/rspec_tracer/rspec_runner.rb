# frozen_string_literal: true

module RSpecTracer
  module RSpecRunner
    # rubocop:disable Metrics/AbcSize
    def run_specs(example_groups)
      actual_count = RSpec.world.example_count
      RSpecTracer.no_examples = actual_count.zero?

      if RSpecTracer.no_examples
        RSpecTracer.running = true

        super(example_groups)

        return
      end

      starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      filtered_examples, filtered_example_groups = RSpecTracer.filter_examples

      RSpec.world.instance_variable_set(:@filtered_examples, filtered_examples)
      RSpec.world.instance_variable_set(:@example_groups, filtered_example_groups)

      current_count = RSpec.world.example_count
      ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      elpased = RSpecTracer::TimeFormatter.format_time(ending - starting)

      puts
      puts <<-EXAMPLES.strip.gsub(/\s+/, ' ')
        RSpec tracer is running #{current_count} examples (actual: #{actual_count},
        skipped: #{actual_count - current_count}) (took #{elpased})
      EXAMPLES

      RSpecTracer.running = true

      super(filtered_example_groups)
    end
    # rubocop:enable Metrics/AbcSize
  end
end
