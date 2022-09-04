# frozen_string_literal: true

require_relative 'cache'
require_relative 'reporter'

module RSpecTracer
  class Runner
    EXAMPLE_RUN_REASON = {
      explicit_run: 'Explicit run',
      no_cache: 'No cache',
      interrupted: 'Interrupted previously',
      flaky_example: 'Flaky example',
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
      return true if RSpecTracer.run_all_examples

      !@cache.all_examples.key?(example_id) || @filtered_examples.key?(example_id)
    end

    def run_example_reason(example_id)
      return EXAMPLE_RUN_REASON[:explicit_run] if RSpecTracer.run_all_examples

      @filtered_examples[example_id] || EXAMPLE_RUN_REASON[:no_cache]
    end

    def register_example(example)
      @reporter.register_example(example)
    end

    def deregister_duplicate_examples
      @reporter.deregister_duplicate_examples
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

    def register_interrupted_examples
      @reporter.register_interrupted_examples
    end

    def register_deleted_examples
      @reporter.register_deleted_examples(@cache.all_examples)
    end

    def generate_missed_coverage
      missed_coverage = Hash.new do |files_coverage, file_path|
        files_coverage[file_path] = Hash.new do |strength, line_number|
          strength[line_number] = 0
        end
      end

      @cache.cached_examples_coverage.each_pair do |example_id, example_coverage|
        example_coverage.each_pair do |file_path, line_coverage|
          next if @reporter.example_interrupted?(example_id) ||
            @reporter.duplicate_example?(example_id)

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

    def register_dependency(examples_coverage)
      filtered_files = Set.new

      examples_coverage.each_pair do |example_id, example_coverage|
        next if @reporter.example_interrupted?(example_id) ||
          @reporter.duplicate_example?(example_id)

        register_example_files_dependency(example_id)

        example_coverage.each_key do |file_path|
          next if filtered_files.include?(file_path)

          filtered_files << file_path unless register_file_dependency(example_id, file_path)
        end
      end

      @reporter.pending_examples.each do |example_id|
        register_example_files_dependency(example_id)
      end
    end

    def register_traced_dependency(examples_traced_files)
      rspec_required_files = fetch_rspec_required_files

      examples_traced_files.each_pair do |example_id, traced_files|
        required_files = traced_files | rspec_required_files

        required_files.each { |file_path| register_file_dependency(example_id, file_path) }
      end
    end

    def register_examples_coverage(examples_coverage)
      @reporter.register_examples_coverage(examples_coverage)
    end

    private

    def filter_examples_to_run
      starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @changed_files = fetch_changed_files

      filter_by_example_status
      filter_by_files_changed

      ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      elapsed = RSpecTracer::TimeFormatter.format_time(ending - starting)

      RSpecTracer.logger.debug "RSpec tracer processed cache (took #{elapsed})"
    end

    def filter_by_example_status
      add_previously_interrupted_examples
      add_previously_flaky_examples
      add_previously_failed_examples
      add_previously_pending_examples
    end

    def filter_by_files_changed
      @cache.dependency.each_pair do |example_id, files|
        next if @filtered_examples.key?(example_id)
        next if (@changed_files & files).empty?

        @filtered_examples[example_id] = EXAMPLE_RUN_REASON[:files_changed]
      end
    end

    def add_previously_interrupted_examples
      @cache.interrupted_examples.each do |example_id|
        @filtered_examples[example_id] = EXAMPLE_RUN_REASON[:interrupted]
      end
    end

    def add_previously_flaky_examples
      @cache.flaky_examples.each do |example_id|
        @filtered_examples[example_id] = EXAMPLE_RUN_REASON[:flaky_example]

        next unless @cache.dependency.key?(example_id)
        next unless (@changed_files & @cache.dependency[example_id]).empty?

        @reporter.register_possibly_flaky_example(example_id)
      end
    end

    def add_previously_failed_examples
      @cache.failed_examples.each do |example_id|
        next if @filtered_examples.key?(example_id)

        @filtered_examples[example_id] = EXAMPLE_RUN_REASON[:failed_example]

        next unless @cache.dependency.key?(example_id)
        next unless (@changed_files & @cache.dependency[example_id]).empty?

        @reporter.register_possibly_flaky_example(example_id)
      end
    end

    def add_previously_pending_examples
      @cache.pending_examples.each do |example_id|
        @filtered_examples[example_id] = EXAMPLE_RUN_REASON[:pending_example]
      end
    end

    def fetch_changed_files
      @cache.all_files.each_value do |cached_file|
        file_name = cached_file[:file_name]
        source_file = RSpecTracer::SourceFile.from_name(file_name)

        if source_file.nil?
          @reporter.on_file_deleted(file_name)
        elsif cached_file[:digest] != source_file[:digest]
          @reporter.on_file_modified(file_name)
        end
      end

      @reporter.modified_files | @reporter.deleted_files
    end

    def fetch_rspec_required_files
      rspec_root = RSpec::Core::RubyProject.root
      rspec_path = RSpec.configuration.default_path

      RSpec.configuration.requires.each_with_object([]) do |file_name, required_files|
        file_name = "#{file_name}.rb" if File.extname(file_name).empty?
        file_path = File.join(rspec_root, rspec_path, file_name)

        required_files << file_path if File.file?(file_path)
      end
    end

    def register_example_files_dependency(example_id)
      return if @reporter.example_interrupted?(example_id) ||
        @reporter.duplicate_example?(example_id)

      example = @reporter.all_examples[example_id]

      register_example_file_dependency(example_id, example[:file_name])

      return if example[:rerun_file_name] == example[:file_name]

      register_example_file_dependency(example_id, example[:rerun_file_name])
    end

    def register_example_file_dependency(example_id, file_name)
      return if @reporter.example_interrupted?(example_id) ||
        @reporter.duplicate_example?(example_id)

      source_file = RSpecTracer::SourceFile.from_name(file_name)

      @reporter.register_source_file(source_file)
      @reporter.register_dependency(example_id, file_name)
    end

    def register_file_dependency(example_id, file_path)
      return if @reporter.example_interrupted?(example_id) ||
        @reporter.duplicate_example?(example_id)

      source_file = RSpecTracer::SourceFile.from_path(file_path)

      return false if RSpecTracer.filters.any? { |filter| filter.match?(source_file) }

      @reporter.register_source_file(source_file)
      @reporter.register_dependency(example_id, source_file[:file_name])

      true
    end
  end
end
