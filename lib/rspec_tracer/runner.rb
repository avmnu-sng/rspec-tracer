# frozen_string_literal: true

require_relative 'cache'
require_relative 'reporter'

module RSpecTracer
  class Runner
    EXAMPLE_RUN_REASON = {
      explicit_run: 'Explicit run',
      no_cache: 'No cache',
      failed_example: 'Failed previously',
      pending_example: 'Pending previously',
      files_changed: 'Files changed'
    }.freeze

    attr_reader :cache, :reporter

    def initialize
      @cache = RSpecTracer::Cache.new
      @reporter = RSpecTracer::Reporter.new
      @filtered_examples = {}

      @cache.load_cache_for_run
      filter_examples_to_run
    end

    def run_example?(example_id)
      return true if explicit_run?

      !@cache.all_examples.key?(example_id) || @filtered_examples.key?(example_id)
    end

    def run_example_reason(example_id)
      return EXAMPLE_RUN_REASON[:explicit_run] if explicit_run?

      @filtered_examples[example_id] || EXAMPLE_RUN_REASON[:no_cache]
    end

    def register_example(example)
      @reporter.register_example(example)
    end

    def on_example_skipped(example_id)
      @reporter.on_example_skipped(example_id)
    end

    def on_example_passed(example_id, execution_result)
      @reporter.on_example_passed(example_id, execution_result)
    end

    def on_example_failed(example_id, execution_result)
      @reporter.on_example_failed(example_id, execution_result)
    end

    def on_example_pending(example_id, execution_result)
      @reporter.on_example_pending(example_id, execution_result)
    end

    def register_deleted_examples
      @reporter.register_deleted_examples(@cache.all_examples)
    end

    # rubocop:disable Metrics/AbcSize
    def generate_missed_coverage
      missed_coverage = Hash.new do |files_coverage, file_path|
        files_coverage[file_path] = Hash.new do |strength, line_number|
          strength[line_number] = 0
        end
      end

      @cache.cached_examples_coverage.each_pair do |example_id, example_coverage|
        example_coverage.each_pair do |file_path, line_coverage|
          next unless @reporter.example_skipped?(example_id)

          file_name = RSpecTracer::SourceFile.file_name(file_path)

          next if @reporter.file_deleted?(file_name)

          line_coverage.each_pair do |line_number, strength|
            missed_coverage[file_path][line_number] += strength
          end
        end
      end

      missed_coverage
    end
    # rubocop:enable Metrics/AbcSize

    def register_dependency(examples_coverage)
      examples_coverage.each_pair do |example_id, example_coverage|
        register_example_files_dependency(example_id)

        example_coverage.each_key do |file_path|
          source_file = RSpecTracer::SourceFile.from_path(file_path)

          next if RSpecTracer.filters.any? { |filter| filter.match?(source_file) }

          @reporter.register_source_file(source_file)
          @reporter.register_dependency(example_id, source_file[:file_name])
        end
      end
    end

    def register_untraced_dependency(trace_point_files)
      untraced_files = generate_untraced_files(trace_point_files)

      untraced_files.each do |file_path|
        source_file = RSpecTracer::SourceFile.from_path(file_path)

        next if RSpecTracer.filters.any? { |filter| filter.match?(source_file) }

        @reporter.register_source_file(source_file)

        @reporter.all_examples.each_key do |example_id|
          @reporter.register_dependency(example_id, source_file[:file_name])
        end
      end
    end

    def register_examples_coverage(examples_coverage)
      @reporter.register_examples_coverage(examples_coverage)
    end

    def generate_report
      %i[
        all_files
        all_examples
        dependency
        examples_coverage
      ].each do |report_type|
        send("generate_#{report_type}_report")
      end

      @reporter.generate_reverse_dependency_report
      @reporter.generate_last_run_report

      generate_failed_examples_report
      generate_pending_examples_report

      @reporter.write_reports
    end

    private

    def explicit_run?
      ENV.fetch('RSPEC_TRACER_NO_SKIP', 'false') == 'true'
    end

    def filter_examples_to_run
      add_previously_failed_examples
      add_previously_pending_examples
      filter_by_files_changed
    end

    def add_previously_failed_examples
      @cache.failed_examples.each do |example_id|
        @filtered_examples[example_id] = EXAMPLE_RUN_REASON[:failed_example]
      end
    end

    def add_previously_pending_examples
      @cache.pending_examples.each do |example_id|
        @filtered_examples[example_id] = EXAMPLE_RUN_REASON[:pending_example]
      end
    end

    def filter_by_files_changed
      @cache.dependency.each_pair do |example_id, files|
        next if @filtered_examples.key?(example_id)

        files.each do |file_name|
          break if filtered_by_file_changed?(example_id, file_name)
        end
      end
    end

    def filtered_by_file_changed?(example_id, file_name)
      if @reporter.file_changed?(file_name)
        @filtered_examples[example_id] = EXAMPLE_RUN_REASON[:files_changed]

        return true
      end

      source_file = registered_source_file(file_name)

      return false if source_file &&
        @cache.all_files[file_name][:digest] == source_file[:digest]

      @filtered_examples[example_id] = EXAMPLE_RUN_REASON[:files_changed]

      if source_file.nil?
        @reporter.on_file_deleted(file_name)
      else
        @reporter.on_file_modified(file_name)
      end

      true
    end

    def generate_untraced_files(trace_point_files)
      all_files = @reporter.all_files
        .each_value
        .with_object([]) { |source_file, files| files << source_file[:file_path] }

      (trace_point_files | fetch_rspec_required_files) - all_files
    end

    def fetch_rspec_required_files
      rspec_root = RSpec::Core::RubyProject.root
      rspec_path = RSpec.configuration.default_path

      RSpec.configuration.requires.map do |file_name|
        file_name = "#{file_name}.rb" if File.extname(file_name).empty?

        File.join(rspec_root, rspec_path, file_name)
      end
    end

    def register_example_files_dependency(example_id)
      example = @reporter.all_examples[example_id]

      register_example_file_dependency(example_id, example[:file_name])

      return if example[:rerun_file_name] == example[:file_name]

      register_example_file_dependency(example_id, example[:rerun_file_name])
    end

    def register_example_file_dependency(example_id, file_name)
      source_file = registered_source_file(file_name)

      @reporter.register_source_file(source_file)
      @reporter.register_dependency(example_id, file_name)
    end

    def registered_source_file(file_name)
      @reporter.all_files[file_name] || RSpecTracer::SourceFile.from_name(file_name)
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

    def generate_failed_examples_report
      @cache.failed_examples.each do |example_id|
        next if @reporter.example_deleted?(example_id)

        @reporter.register_failed_example(example_id)
      end
    end

    def generate_pending_examples_report
      @cache.pending_examples.each do |example_id|
        next if @reporter.example_deleted?(example_id)

        @reporter.register_pending_example(example_id)
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
  end
end
