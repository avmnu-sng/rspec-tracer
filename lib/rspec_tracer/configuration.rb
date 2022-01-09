# frozen_string_literal: true

require_relative 'filter'
require_relative 'logger'

module RSpecTracer
  module Configuration
    class InvalidUsageError < StandardError; end

    ALLOWED_CONFIGURER = %w[
      lib/rspec_tracer/load_default_config.rb
      lib/rspec_tracer/load_global_config.rb
      lib/rspec_tracer/load_local_config.rb
    ].freeze

    DEFAULT_CACHE_DIR = 'rspec_tracer_cache'
    DEFAULT_COVERAGE_DIR = 'rspec_tracer_coverage'
    DEFAULT_REPORT_DIR = 'rspec_tracer_report'
    DEFAULT_LOCK_FILE = 'rspec_tracer.lock'

    LOG_LEVEL = {
      off: 0,
      debug: 1,
      info: 2,
      warn: 3,
      error: 4
    }.freeze

    def configure(&block)
      configurers = caller_locations(1, 2).map(&:path)
      invalid = configurers.none? do |configurer|
        ALLOWED_CONFIGURER.any? do |allowed_configurer|
          configurer.end_with?(allowed_configurer)
        end
      end

      raise InvalidUsageError, 'You must define configurations in a .rspec-tracer file' if invalid

      RSpecTracer::Configuration.module_exec do
        RSpecTracer::Configuration.private_instance_methods(false).each do |method_name|
          alias_method "_#{method_name}".to_sym, method_name

          define_method method_name do |*args|
            send("_#{method_name}".to_sym, *args)
          end
        end
      end

      Docile.dsl_eval(self, &block)
    end

    private

    def root(root = nil)
      return @root if defined?(@root) && root.nil?

      @cache_path = nil
      @report_path = nil
      @coverage_path = nil

      @root = File.expand_path(root || Dir.getwd)
    end

    def project_name(new_name = nil)
      return @project_name if defined?(@project_name) && @project_name && new_name.nil?

      @project_name = new_name if new_name.is_a?(String)
      @project_name ||= File.basename(root.split('/').last).capitalize.tr('_', ' ')
    end

    def cache_dir(dir = nil)
      return @cache_dir if defined?(@cache_dir) && dir.nil?

      @cache_path = nil
      @cache_dir = (dir || ENV['RSPEC_TRACER_CACHE_DIR'] || DEFAULT_CACHE_DIR)
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

    def report_dir(dir = nil)
      return @report_dir if defined?(@report_dir) && dir.nil?

      @report_path = nil
      @report_dir ||= (dir || ENV['RSPEC_TRACER_REPORT_DIR'] || DEFAULT_REPORT_DIR)
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

    def coverage_dir(dir = nil)
      return @coverage_dir if defined?(@coverage_dir) && dir.nil?

      @coverage_path = nil
      @coverage_dir ||= (dir || ENV['RSPEC_TRACER_COVERAGE_DIR'] || DEFAULT_COVERAGE_DIR)
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

    def reports_s3_path(s3_path = nil)
      return @reports_s3_path if defined?(@reports_s3_path) && s3_path.nil?

      @reports_s3_path = s3_path if valid_s3_path?(s3_path)
      @reports_s3_path ||= ENV['RSPEC_TRACER_REPORTS_S3_PATH'] if valid_s3_path?(ENV['RSPEC_TRACER_REPORTS_S3_PATH'])
    end

    def use_local_aws(new_flag = nil)
      return @use_local_aws if defined?(@use_local_aws) && new_flag.nil?

      @use_local_aws = (new_flag == true)
      @use_local_aws ||= (ENV['RSPEC_TRACER_USE_LOCAL_AWS'] == 'true')
    end

    def upload_non_ci_reports(new_flag = nil)
      return @upload_non_ci_reports if defined?(@upload_non_ci_reports) && new_flag.nil?

      @upload_non_ci_reports = (new_flag == true)
      @upload_non_ci_reports ||= (ENV['RSPEC_TRACER_UPLOAD_NON_CI_REPORTS'] == 'true')
    end

    def run_all_examples(new_flag = nil)
      return @run_all_examples if defined?(@run_all_examples) && new_flag.nil?

      @run_all_examples = (new_flag == true)
      @run_all_examples ||= (ENV['RSPEC_TRACER_RUN_ALL_EXAMPLES'] == 'true')
    end

    def fail_on_duplicates(new_flag = nil)
      return @fail_on_duplicates if defined?(@fail_on_duplicates) && new_flag.nil?

      @fail_on_duplicates = (new_flag == true)
      @fail_on_duplicates ||= (ENV['RSPEC_TRACER_FAIL_ON_DUPLICATES'] != 'false')
    end

    def lock_file(new_file = nil)
      return @lock_file if defined?(@lock_file) && @lock_file && new_file.nil?

      @lock_file = new_file if new_file.is_a?(String)
      @lock_file ||= (ENV['RSPEC_TRACER_LOCK_FILE'] || DEFAULT_LOCK_FILE)
    end

    def log_level(new_level = nil)
      return @log_level if defined?(@log_level) && @log_level && new_level.nil?

      @logger = nil
      @log_level = LOG_LEVEL[(new_level || ENV['RSPEC_TRACER_LOG_LEVEL']).to_s.to_sym].to_i
    end

    def logger
      @logger ||= RSpecTracer::Logger.new(log_level)
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

    def filters=(new_filteres)
      raise NotImplementedError
    end

    def add_coverage_filter(filter = nil, &block)
      coverage_filters << parse_filter(filter, &block)
    end

    def coverage_filters
      @coverage_filters ||= []
    end

    def coverage_filters=(new_filteres)
      raise NotImplementedError
    end

    def valid_s3_path?(s3_path)
      uri = URI.parse(s3_path)

      uri.scheme == 's3' && !uri.host.empty?
    rescue URI::InvalidURIError => _e
      false
    end

    def parallel_tests_id
      if ParallelTests.first_process?
        'parallel_tests_1'
      else
        "parallel_tests_#{ENV['TEST_ENV_NUMBER']}"
      end
    end

    def parse_filter(filter = nil, &block)
      arg = filter || block

      raise ArgumentError, 'Either a filter or a block required' if arg.nil?

      RSpecTracer::Filter.register(arg)
    end
  end
end
