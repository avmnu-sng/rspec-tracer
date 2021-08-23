# frozen_string_literal: true

module RSpecTracer
  module RSpecRunner
    def run_specs(_example_groups)
      actual_count = RSpec.world.example_count
      filtered_examples, example_groups = RSpecTracer.filter_examples

      RSpec.world.instance_variable_set(:@filtered_examples, filtered_examples)
      RSpec.world.instance_variable_set(:@example_groups, example_groups)

      current_count = RSpec.world.example_count

      puts
      puts <<-EXAMPLES.strip.gsub(/\s+/, ' ')
        RSpec tracer is running #{current_count} examples (actual: #{actual_count},
        skipped: #{actual_count - current_count})
      EXAMPLES

      RSpecTracer.running = true

      super(example_groups)
    end
  end
end
