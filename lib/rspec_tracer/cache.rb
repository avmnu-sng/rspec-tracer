# frozen_string_literal: true

module RSpecTracer
  class Cache
    attr_reader :all_examples, :duplicate_examples, :interrupted_examples,
                :flaky_examples, :failed_examples, :pending_examples, :skipped_examples,
                :all_files, :dependency, :examples_coverage, :run_id

    def initialize
      @cached = false

      @all_examples = {}
      @duplicate_examples = {}
      @interrupted_examples = Set.new
      @flaky_examples = Set.new
      @failed_examples = Set.new
      @pending_examples = Set.new
      @all_files = {}
      @dependency = Hash.new { |hash, key| hash[key] = Set.new }
    end

    def load_cache_for_run
      return if @cached

      cache_path = RSpecTracer.cache_path
      cache_path = File.dirname(cache_path) if RSpecTracer.parallel_tests?
      run_id = last_run_id(cache_path)

      return if run_id.nil?

      starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      cache_dir = File.join(cache_path, run_id)

      load_all_examples_cache(cache_dir)
      load_duplicate_examples_cache(cache_dir)
      load_interrupted_examples_cache(cache_dir)
      load_flaky_examples_cache(cache_dir)
      load_failed_examples_cache(cache_dir)
      load_pending_examples_cache(cache_dir)
      load_all_files_cache(cache_dir)
      load_dependency_cache(cache_dir)

      ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      @cached = true

      elapsed = RSpecTracer::TimeFormatter.format_time(ending - starting)

      RSpecTracer.logger.debug "RSpec tracer loaded cache from #{cache_dir} (took #{elapsed})"
    end

    def cached_examples_coverage
      return @examples_coverage if defined?(@examples_coverage)

      cache_path = RSpecTracer.cache_path
      cache_path = File.dirname(cache_path) if RSpecTracer.parallel_tests?
      run_id = last_run_id(cache_path)

      return @examples_coverage = {} if run_id.nil?

      starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      cache_dir = File.join(cache_path, run_id)
      coverage = load_examples_coverage_cache(cache_dir)
      ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      elapsed = RSpecTracer::TimeFormatter.format_time(ending - starting)

      RSpecTracer.logger.debug "RSpec tracer loaded cached examples coverage (took #{elapsed})"

      coverage
    end

    private

    def last_run_id(cache_dir)
      file_name = File.join(cache_dir, 'last_run.json')

      return unless File.file?(file_name)

      JSON.parse(File.read(file_name))['run_id']
    end

    def load_all_examples_cache(cache_dir, discard_run_reason: true)
      file_name = File.join(cache_dir, 'all_examples.json')

      return unless File.file?(file_name)

      @all_examples = JSON.parse(File.read(file_name)).transform_values do |examples|
        examples.transform_keys(&:to_sym)
      end

      @all_examples.each_value do |example|
        example[:execution_result].transform_keys!(&:to_sym) if example.key?(:execution_result)
        example[:run_reason] = nil if discard_run_reason
      end
    end

    def load_duplicate_examples_cache(cache_dir)
      file_name = File.join(cache_dir, 'duplicate_examples.json')

      return unless File.file?(file_name)

      @duplicate_examples = JSON.parse(File.read(file_name)).transform_values do |examples|
        examples.map { |example| example.transform_keys(&:to_sym) }
      end
    end

    def load_interrupted_examples_cache(cache_dir)
      file_name = File.join(cache_dir, 'interrupted_examples.json')

      return unless File.file?(file_name)

      @interrupted_examples = JSON.parse(File.read(file_name)).to_set
    end

    def load_flaky_examples_cache(cache_dir)
      file_name = File.join(cache_dir, 'flaky_examples.json')

      return unless File.file?(file_name)

      @flaky_examples = JSON.parse(File.read(file_name)).to_set
    end

    def load_failed_examples_cache(cache_dir)
      file_name = File.join(cache_dir, 'failed_examples.json')

      return unless File.file?(file_name)

      @failed_examples = JSON.parse(File.read(file_name)).to_set
    end

    def load_pending_examples_cache(cache_dir)
      file_name = File.join(cache_dir, 'pending_examples.json')

      return unless File.file?(file_name)

      @pending_examples = JSON.parse(File.read(file_name)).to_set
    end

    def load_skipped_examples_cache(cache_dir)
      file_name = File.join(cache_dir, 'skipped_examples.json')

      return unless File.file?(file_name)

      @skipped_examples = JSON.parse(File.read(file_name)).to_set
    end

    def load_all_files_cache(cache_dir)
      file_name = File.join(cache_dir, 'all_files.json')

      return unless File.file?(file_name)

      @all_files = JSON.parse(File.read(file_name)).transform_values do |files|
        files.transform_keys(&:to_sym)
      end
    end

    def load_dependency_cache(cache_dir)
      file_name = File.join(cache_dir, 'dependency.json')

      return unless File.file?(file_name)

      @dependency = JSON.parse(File.read(file_name)).transform_values(&:to_set)
    end

    def load_examples_coverage_cache(cache_dir)
      file_name = File.join(cache_dir, 'examples_coverage.json')

      return unless File.file?(file_name)

      @examples_coverage = JSON.parse(File.read(file_name))
    end
  end
end
