# frozen_string_literal: true

module RSpecTracer
  module RSpec
    # Prepended onto `RSpec::Core::Runner` by
    # `RSpecTracer::RSpec::Installation.install!`. Replaces the 1.x
    # `RSpecTracer::RSpecRunner` singleton-class prepend that the
    # ObjectSpace loop in `setup_rspec?` used to install.
    #
    # Responsibilities, in `run_specs` order:
    #   1. Early-return to `super` if the engine hasn't been set up
    #      (defensive; keeps the suite green under `RSPEC_TRACER_DISABLE=1`
    #      or when the user forgot to call `RSpecTracer.start`).
    #   2. Partition `RSpec.world.filtered_examples` via the engine:
    #      tracked examples go through identity-hashing + filter decision;
    #      ignored examples (matched by `Configuration#ignore_spec_files`)
    #      pass through untouched - RSpec still runs them, but the tracer
    #      never sees them. Closes #41.
    #   3. Detect duplicate example identities. `fail_on_duplicates=true`
    #      surfaces via `::Kernel.exit(1)` in `at_exit_behavior`; the
    #      hook passes `[]` to super so RSpec doesn't execute anything.
    #   4. Overwrite `RSpec.world.@filtered_examples` +
    #      `@example_groups` with the filtered set, then log the run
    #      banner and delegate to `super`.
    #
    # The user-visible log line - `RSpec tracer is running N examples
    # (actual: N, skipped: N)` - is preserved byte-for-byte from 1.x so
    # cucumber scenarios and CI log parsers keep working.
    module RunnerHook
      def run_specs(example_groups)
        return super unless RSpecTracer.engine

        actual_count = ::RSpec.world.example_count
        if _rspec_tracer_no_examples?(actual_count)
          super
          return
        end

        starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        filtered_examples_map, filtered_example_groups = _rspec_tracer_build_filter_decision

        if _rspec_tracer_duplicates_detected?
          RSpecTracer.running = true
          RSpecTracer.duplicate_examples = RSpecTracer.fail_on_duplicates
          super([])
          return
        end

        ::RSpec.world.instance_variable_set(:@filtered_examples, filtered_examples_map)
        ::RSpec.world.instance_variable_set(:@example_groups, filtered_example_groups)

        current_count = ::RSpec.world.example_count
        ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        elapsed = RSpecTracer::TimeFormatter.format_time(ending - starting)

        RSpecTracer.logger.info <<-EXAMPLES.strip.gsub(/\s+/, ' ')
          RSpec tracer is running #{current_count} examples (actual: #{actual_count},
          skipped: #{actual_count - current_count}) (took #{elapsed})
        EXAMPLES

        RSpecTracer.running = true

        super(filtered_example_groups)
      end

      private

      def _rspec_tracer_no_examples?(actual_count)
        return false unless actual_count.zero?

        RSpecTracer.running = true
        RSpecTracer.no_examples = true
      end

      # Walk RSpec.world.filtered_examples once. For each example, either:
      #   - ignored (matches Configuration#ignore_spec_files): pass straight
      #     through; RSpec runs it, engine never sees it, so no identity
      #     hash is computed, no duplicate detection, no filter decision
      #     contributes to its state.
      #   - tracked: build a tracer-example, tag metadata with the id, and
      #     ask the engine whether to run. Skip-decisions go to
      #     Engine#on_example_skipped so the skipped_examples snapshot
      #     entry persists across warm runs (M4.3 fix #2).
      #
      # The loop body is cohesive - splitting it for ABC/MethodLength
      # would scatter the one-pass filter decision across unrelated
      # private helpers.
      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      def _rspec_tracer_build_filter_decision
        to_run = Hash.new { |hash, group| hash[group] = [] }
        groups = Set.new
        engine = RSpecTracer.engine

        ::RSpec.world.filtered_examples.each_pair do |example_group, examples|
          examples.each do |example|
            if RSpecTracer.ignore_spec_file?(example.metadata[:file_path])
              to_run[example_group] << example
              groups << example.example_group.parent_groups.last
              next
            end

            tracer_example = RSpecTracer::Example.from(example)
            example_id = tracer_example[:example_id]
            example.metadata[:rspec_tracer_example_id] = example_id

            if engine.run_example?(example_id)
              run_reason = engine.run_example_reason(example_id)
              tracer_example[:run_reason] = run_reason
              example.metadata[:description] = "#{example.description} (#{run_reason})"

              to_run[example_group] << example
              groups << example.example_group.parent_groups.last

              engine.register_example(tracer_example)
            else
              engine.on_example_skipped(example_id)
            end
          end
        end

        engine.deregister_duplicate_examples

        [to_run, groups.to_a]
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      def _rspec_tracer_duplicates_detected?
        duplicates = RSpecTracer.engine.duplicate_examples
        return false if duplicates.empty?

        total = duplicates.sum { |_, entries| entries.count }
        hashes = duplicates.size
        RSpecTracer.logger.error(
          "RSpec tracer detected #{total} duplicate example(s) across #{hashes} identity hash(es)"
        )
        true
      end
    end
  end
end
