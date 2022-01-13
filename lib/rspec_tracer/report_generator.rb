# frozen_string_literal: true

module RSpecTracer
  class ReportGenerator
    def initialize(reporter, cache)
      @reporter = reporter
      @cache = cache
    end

    def reverse_dependency_report
      reverse_dependency = Hash.new do |examples, file_name|
        examples[file_name] = {
          example_count: 0,
          examples: Hash.new(0)
        }
      end

      @reporter.dependency.each_pair do |example_id, files|
        next if @reporter.interrupted_examples.include?(example_id)

        example_file = @reporter.all_examples[example_id][:rerun_file_name]

        files.each do |file_name|
          reverse_dependency[file_name][:example_count] += 1
          reverse_dependency[file_name][:examples][example_file] += 1
        end
      end

      reverse_dependency.transform_values! do |data|
        {
          example_count: data[:example_count],
          examples: data[:examples].sort_by { |file_name, count| [-count, file_name] }.to_h
        }
      end

      reverse_dependency.sort_by { |file_name, data| [-data[:example_count], file_name] }.to_h
    end

    def generate_report
      generate_last_run_report
      generate_examples_status_report

      %i[all_files all_examples dependency examples_coverage reverse_dependency].each do |report_type|
        starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        send("generate_#{report_type}_report")

        ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        elapsed = RSpecTracer::TimeFormatter.format_time(ending - starting)

        RSpecTracer.logger.debug "RSpec tracer generated #{report_type.to_s.tr('_', ' ')} report (took #{elapsed})"
      end
    end

    private

    def generate_last_run_report
      @reporter.last_run = {
        pid: RSpecTracer.pid,
        actual_count: RSpec.world.example_count + @reporter.skipped_examples.count,
        example_count: RSpec.world.example_count,
        duplicate_examples: @reporter.duplicate_examples.sum { |_, examples| examples.count },
        interrupted_examples: @reporter.interrupted_examples.count,
        failed_examples: @reporter.failed_examples.count,
        skipped_examples: @reporter.skipped_examples.count,
        pending_examples: @reporter.pending_examples.count,
        flaky_examples: @reporter.flaky_examples.count
      }
    end

    def generate_examples_status_report
      starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      generate_flaky_examples_report
      generate_failed_examples_report
      generate_pending_examples_report

      ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      elapsed = RSpecTracer::TimeFormatter.format_time(ending - starting)

      RSpecTracer.logger.debug "RSpec tracer generated flaky, failed, and pending examples report (took #{elapsed})"
    end

    def generate_flaky_examples_report
      @reporter.possibly_flaky_examples.each do |example_id|
        next if @reporter.example_deleted?(example_id)
        next unless @cache.flaky_examples.include?(example_id) ||
          @reporter.example_passed?(example_id)

        @reporter.register_flaky_example(example_id)
      end
    end

    def generate_failed_examples_report
      @cache.failed_examples.each do |example_id|
        next if @reporter.example_deleted?(example_id) ||
          @reporter.all_examples.key?(example_id)

        @reporter.register_failed_example(example_id)
      end
    end

    def generate_pending_examples_report
      @cache.pending_examples.each do |example_id|
        next if @reporter.example_deleted?(example_id) ||
          @reporter.all_examples.key?(example_id)

        @reporter.register_pending_example(example_id)
      end
    end

    def generate_all_files_report
      @cache.all_files.each_pair do |file_name, data|
        next if @reporter.all_files.key?(file_name) ||
          @reporter.file_deleted?(file_name)

        @reporter.all_files[file_name] = data
      end
    end

    def generate_all_examples_report
      @cache.all_examples.each_pair do |example_id, data|
        next if @reporter.all_examples.key?(example_id) ||
          @reporter.example_deleted?(example_id)

        @reporter.all_examples[example_id] = data
      end
    end

    def generate_dependency_report
      @cache.dependency.each_pair do |example_id, data|
        next if @reporter.dependency.key?(example_id) ||
          @reporter.example_deleted?(example_id)

        @reporter.dependency[example_id] = data.reject do |file_name|
          @reporter.file_deleted?(file_name)
        end
      end

      @reporter.dependency.transform_values!(&:to_a)
    end

    def generate_examples_coverage_report
      @cache.cached_examples_coverage.each_pair do |example_id, data|
        next if @reporter.examples_coverage.key?(example_id) ||
          @reporter.example_deleted?(example_id)

        @reporter.examples_coverage[example_id] = data.reject do |file_name|
          @reporter.file_deleted?(file_name)
        end
      end
    end

    def generate_reverse_dependency_report
      @reporter.reverse_dependency = reverse_dependency_report
    end
  end
end
