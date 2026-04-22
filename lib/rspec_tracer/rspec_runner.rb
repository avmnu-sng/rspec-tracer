# frozen_string_literal: true

module RSpecTracer
  module RSpecRunner
    def run_specs(example_groups)
      actual_count = RSpec.world.example_count

      if _no_examples?(actual_count)
        super

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
      duplicates = _tracer_duplicate_examples
      return false if duplicates.empty?

      _tracer_print_duplicate_examples(duplicates)

      RSpecTracer.running = true
      RSpecTracer.duplicate_examples = RSpecTracer.fail_on_duplicates
    end

    def _tracer_duplicate_examples
      return RSpecTracer.engine.duplicate_examples if RSpecTracer.v2_engine?

      RSpecTracer.runner.reporter.duplicate_examples
    end

    def _tracer_print_duplicate_examples(duplicates)
      return RSpecTracer.report_writer.print_duplicate_examples if RSpecTracer.report_writer

      # v2 mode has no legacy report_writer; surface the duplicates
      # through the logger so the signal isn't lost.
      total = duplicates.sum { |_, entries| entries.count }
      hashes = duplicates.size
      RSpecTracer.logger.error(
        "RSpec tracer detected #{total} duplicate example(s) across #{hashes} identity hash(es)"
      )
    end
  end
end
