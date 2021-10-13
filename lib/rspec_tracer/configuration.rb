# frozen_string_literal: true

require_relative 'filter'

module RSpecTracer
  module Configuration
    DEFAULT_CACHE_DIR = 'rspec_tracer_cache'
    DEFAULT_REPORT_DIR = 'rspec_tracer_report'
    DEFAULT_COVERAGE_DIR = 'rspec_tracer_coverage'

    attr_writer :filters, :coverage_filters

    def root(root = nil)
      return @root if defined?(@root) && root.nil?

      @cache_path = nil
      @report_path = nil
      @coverage_path = nil

      @root = File.expand_path(root || Dir.getwd)
    end

    def project_name
      @project_name ||= File.basename(root).capitalize
    end

    def cache_dir
      @cache_dir ||= (ENV['RSPEC_TRACER_CACHE_DIR'] || DEFAULT_CACHE_DIR)
    end

    def cache_path
      @cache_path ||= begin
        cache_path = File.expand_path(cache_dir, root)
        cache_path = File.join(cache_path, ENV['TEST_SUITE_ID'].to_s) if ENV['TEST_SUITE_ID']
        cache_path = File.join(cache_path, parallel_tests_id) if RSpecTracer.parallel_tests?

        FileUtils.mkdir_p(cache_path)

        cache_path
      end
    end

    def report_dir
      @report_dir ||= (ENV['RSPEC_TRACER_REPORT_DIR'] || DEFAULT_REPORT_DIR)
    end

    def report_path
      @report_path ||= begin
        report_path = File.expand_path(report_dir, root)
        report_path = File.join(report_path, ENV['TEST_SUITE_ID'].to_s) if ENV['TEST_SUITE_ID']
        report_path = File.join(report_path, parallel_tests_id) if RSpecTracer.parallel_tests?

        FileUtils.mkdir_p(report_path)

        report_path
      end
    end

    def coverage_dir
      @coverage_dir ||= (ENV['RSPEC_TRACER_COVERAGE_DIR'] || DEFAULT_COVERAGE_DIR)
    end

    def coverage_path
      @coverage_path ||= begin
        coverage_path = File.expand_path(coverage_dir, root)
        coverage_path = File.join(coverage_path, ENV['TEST_SUITE_ID'].to_s) if ENV['TEST_SUITE_ID']
        coverage_path = File.join(coverage_path, parallel_tests_id) if RSpecTracer.parallel_tests?

        FileUtils.mkdir_p(coverage_path)

        coverage_path
      end
    end

    def coverage_track_files(glob)
      @coverage_track_files = glob
    end

    def coverage_tracked_files
      @coverage_track_files if defined?(@coverage_track_files)
    end

    def add_filter(filter = nil, &block)
      filters << parse_filter(filter, &block)
    end

    def filters
      @filters ||= []
    end

    def add_coverage_filter(filter = nil, &block)
      coverage_filters << parse_filter(filter, &block)
    end

    def coverage_filters
      @coverage_filters ||= []
    end

    def parallel_tests_lock_file
      '/tmp/parallel_tests.lock'
    end

    def verbose?
      @verbose ||= (ENV.fetch('RSPEC_TRACER_VERBOSE', 'false') == 'true')
    end

    def configure(&block)
      Docile.dsl_eval(self, &block)
    end

    private

    def parallel_tests_id
      if ParallelTests.first_process?
        'parallel_tests_1'
      else
        "parallel_tests_#{ENV['TEST_ENV_NUMBER']}"
      end
    end

    def at_exit(&block)
      return Proc.new unless RSpecTracer.running || block

      @at_exit = block if block
      @at_exit ||= proc { RSpecTracer.at_exit_behavior }
    end

    def parse_filter(filter = nil, &block)
      arg = filter || block

      raise ArgumentError, 'Either a filter or a block required' if arg.nil?

      RSpecTracer::Filter.register(arg)
    end
  end
end
