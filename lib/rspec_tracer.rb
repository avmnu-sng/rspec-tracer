# frozen_string_literal: true

require 'English'

require 'digest/md5'
require 'docile'
require 'fileutils'
require 'forwardable'
require 'json'
require 'pathname'
require 'pry'
require 'set'

require_relative 'rspec_tracer/coverage_merger'
require_relative 'rspec_tracer/coverage_reporter'
require_relative 'rspec_tracer/coverage_writer'
require_relative 'rspec_tracer/defaults'
require_relative 'rspec_tracer/example'
require_relative 'rspec_tracer/html_reporter/reporter'
require_relative 'rspec_tracer/load_config'
require_relative 'rspec_tracer/remote_cache/cache'
require_relative 'rspec_tracer/report_generator'
require_relative 'rspec_tracer/report_merger'
require_relative 'rspec_tracer/report_writer'
require_relative 'rspec_tracer/rspec_reporter'
require_relative 'rspec_tracer/rspec_runner'
require_relative 'rspec_tracer/ruby_coverage'
require_relative 'rspec_tracer/runner'
require_relative 'rspec_tracer/source_file'
require_relative 'rspec_tracer/time_formatter'
require_relative 'rspec_tracer/version'

module RSpecTracer
  class << self
    attr_accessor :running, :pid, :no_examples, :duplicate_examples

    def start
      RSpecTracer.running = false
      RSpecTracer.pid = Process.pid

      return if RUBY_ENGINE == 'jruby' && !valid_jruby_opts?

      RSpecTracer.logger.debug "Started RSpec tracer (pid: #{RSpecTracer.pid})"

      parallel_tests_setup
      initial_setup
    end

    # rubocop:disable Metrics/AbcSize
    def filter_examples
      groups = Set.new
      to_run = Hash.new { |hash, group| hash[group] = [] }

      RSpec.world.filtered_examples.each_pair do |example_group, examples|
        examples.each do |example|
          tracer_example = RSpecTracer::Example.from(example)
          example_id = tracer_example[:example_id]
          example.metadata[:rspec_tracer_example_id] = example_id

          if runner.run_example?(example_id)
            run_reason = runner.run_example_reason(example_id)
            tracer_example[:run_reason] = run_reason
            example.metadata[:description] = "#{example.description} (#{run_reason})"

            to_run[example_group] << example
            groups << example.example_group.parent_groups.last

            runner.register_example(tracer_example)
          else
            runner.on_example_skipped(example_id)
          end
        end
      end

      runner.deregister_duplicate_examples

      [to_run, groups.to_a]
    end
    # rubocop:enable Metrics/AbcSize

    def at_exit_behavior
      return unless RSpecTracer.pid == Process.pid && RSpecTracer.running

      ::Kernel.exit(1) if duplicate_examples

      run_exit_tasks
    ensure
      FileUtils.rm_f(RSpecTracer.lock_file) if parallel_tests_last_process?

      RSpecTracer.running = false
    end

    def start_example_trace
      trace_point.enable
    end

    def stop_example_trace(example_id)
      trace_point.disable

      @examples_traced_files[example_id] = @traced_files
      @traced_files = Set.new
    end

    def runner
      return @runner if defined?(@runner)
    end

    def coverage_reporter
      return @coverage_reporter if defined?(@coverage_reporter)
    end

    def report_writer
      return @report_writer if defined?(@report_writer)
    end

    def coverage_merger
      return @coverage_merger if defined?(@coverage_merger)
    end

    def report_merger
      return @report_merger if defined?(@report_merger)
    end

    def trace_point
      return @trace_point if defined?(@trace_point)
    end

    def traced_files
      return @traced_files if defined?(@traced_files)
    end

    def examples_traced_files
      return @examples_traced_files if defined?(@examples_traced_files)
    end

    def simplecov?
      return @simplecov if defined?(@simplecov)
    end

    def parallel_tests?
      return @parallel_tests if defined?(@parallel_tests)
    end

    private

    def valid_jruby_opts?
      require 'jruby'

      return true if Java::OrgJruby::RubyInstanceConfig.FULL_TRACE_ENABLED &&
        JRuby.runtime.object_space_enabled?

      RSpecTracer.logger.warn <<-WARN.strip.gsub(/\s+/, ' ')
        RSpec Tracer is not running as it requires debug and object space enabled. Use
        command line options "--debug" and "-X+O" or set the "debug.fullTrace=true" and
        "objectspace.enabled=true" options in your .jrubyrc file. You can also use
        JRUBY_OPTS="--debug -X+O".
      WARN

      false
    end

    def initial_setup
      unless setup_rspec
        RSpecTracer.logger.error 'Could not find a running RSpec process'

        return
      end

      setup_coverage
      setup_trace_point

      @runner = RSpecTracer::Runner.new
      @coverage_reporter = RSpecTracer::CoverageReporter.new
      @report_writer = RSpecTracer::ReportWriter.new(RSpecTracer.cache_path, @runner.reporter)
    end

    def parallel_tests_setup
      @parallel_tests = !(ENV['TEST_ENV_NUMBER'] && ENV['PARALLEL_TEST_GROUPS']).nil?

      return unless parallel_tests?

      require 'parallel_tests' unless defined?(ParallelTests)

      @coverage_merger = RSpecTracer::CoverageMerger.new
      @report_merger = RSpecTracer::ReportMerger.new
    rescue LoadError => e
      RSpecTracer.logger.error "Failed to load parallel tests (Error: #{e.message})"
    ensure
      track_parallel_tests_test_env_number
    end

    def track_parallel_tests_test_env_number
      return unless parallel_tests?

      File.open(RSpecTracer.lock_file, File::RDWR | File::CREAT, 0o644) do |f|
        f.flock(File::LOCK_EX)

        test_num = [f.read.to_i, ENV['TEST_ENV_NUMBER'].to_i].max

        f.rewind
        f.write("#{test_num}\n")
        f.flush
        f.truncate(f.pos)
      end
    end

    def setup_rspec
      runners = ObjectSpace.each_object(::RSpec::Core::Runner) do |runner|
        runner_clazz = runner.singleton_class
        clazz = RSpecTracer::RSpecRunner

        runner_clazz.prepend(clazz) unless runner_clazz.ancestors.include?(clazz)

        reporter_clazz = runner.configuration.reporter.singleton_class
        clazz = RSpecTracer::RSpecReporter

        reporter_clazz.prepend(clazz) unless reporter_clazz.ancestors.include?(clazz)
      end

      runners.positive?
    end

    def setup_coverage
      @simplecov = defined?(SimpleCov) && SimpleCov.running

      return if simplecov?

      require 'coverage'

      ::Coverage.start
    end

    def setup_trace_point
      @traced_files = Set.new
      @examples_traced_files = {}

      @trace_point = TracePoint.new(:call) do |tp|
        RSpecTracer.traced_files << tp.path if tp.path.start_with?(RSpecTracer.root)
      end
    end

    def run_exit_tasks
      if RSpecTracer.no_examples
        RSpecTracer.logger.info 'Skipped reports generation since all examples were filtered out'
      else
        generate_reports
      end

      simplecov? ? run_simplecov_exit_task : run_coverage_exit_task

      run_parallel_tests_exit_tasks
    end

    def generate_reports
      RSpecTracer.logger.debug "RSpec tracer is generating reports (pid: #{RSpecTracer.pid})"

      process_dependency
      process_coverage

      RSpecTracer::ReportGenerator.new(runner.reporter, runner.cache).generate_report
      report_writer.write_report
      RSpecTracer::HTMLReporter::Reporter.new(RSpecTracer.report_path, runner.reporter).generate_report
    end

    def process_dependency
      starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      runner.register_interrupted_examples
      runner.register_deleted_examples
      runner.register_dependency(coverage_reporter.examples_coverage)
      runner.register_traced_dependency(@examples_traced_files)

      ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      elapsed = RSpecTracer::TimeFormatter.format_time(ending - starting)

      RSpecTracer.logger.debug "RSpec tracer processed dependency (took #{elapsed})"
    end

    def process_coverage
      starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      coverage_reporter.generate_final_examples_coverage
      coverage_reporter.merge_coverage(runner.generate_missed_coverage)
      runner.register_examples_coverage(coverage_reporter.examples_coverage)

      ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      elapsed = RSpecTracer::TimeFormatter.format_time(ending - starting)

      RSpecTracer.logger.debug "RSpec tracer processed coverage (took #{elapsed})"
    end

    def run_simplecov_exit_task
      coverage_clazz = ::Coverage.singleton_class
      clazz = RSpecTracer::RubyCoverage
      coverage_clazz.prepend(clazz) unless coverage_clazz.ancestors.include?(clazz)

      RSpecTracer.logger.debug 'SimpleCov will now generate coverage report (<3 RSpec tracer)'

      coverage_reporter.record_coverage if RSpecTracer.no_examples
    end

    def run_coverage_exit_task
      starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      coverage_reporter.record_coverage if RSpecTracer.no_examples
      coverage_reporter.generate_final_coverage

      file_name = File.join(RSpecTracer.coverage_path, 'coverage.json')
      coverage_writer = RSpecTracer::CoverageWriter.new(file_name, coverage_reporter)

      coverage_writer.write_report

      ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      coverage_writer.print_stats(ending - starting)
    end

    def run_parallel_tests_exit_tasks
      return unless parallel_tests_executed?

      merge_parallel_tests_reports
      write_parallel_tests_merged_report
      merge_parallel_tests_coverage_reports
      write_parallel_tests_coverage_report
      purge_parallel_tests_reports
    end

    def merge_parallel_tests_reports
      return unless parallel_tests_executed?

      starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      reports_dir = []

      1.upto(ENV['PARALLEL_TEST_GROUPS'].to_i) do |test_num|
        cache_path = File.dirname(RSpecTracer.cache_path)
        cache_dir = File.join(cache_path, "parallel_tests_#{test_num}")

        next unless File.directory?(cache_dir)

        run_id = JSON.parse(File.read(File.join(cache_dir, 'last_run.json')))['run_id']

        reports_dir << File.join(cache_dir, run_id)
      end

      report_merger.merge(reports_dir)

      ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      elapsed = RSpecTracer::TimeFormatter.format_time(ending - starting)

      RSpecTracer.logger.debug "RSpec tracer merged parallel tests reports (took #{elapsed})"
    end

    def write_parallel_tests_merged_report
      return unless parallel_tests_executed?

      report_dir = File.dirname(RSpecTracer.cache_path)

      RSpecTracer::ReportWriter.new(report_dir, report_merger).write_report

      report_dir = File.dirname(RSpecTracer.report_path)

      RSpecTracer::HTMLReporter::Reporter.new(report_dir, report_merger).generate_report
    end

    def merge_parallel_tests_coverage_reports
      return unless parallel_tests_executed? && !simplecov?

      starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      reports_dir = []

      1.upto(ENV['PARALLEL_TEST_GROUPS'].to_i) do |test_num|
        coverage_path = File.dirname(RSpecTracer.coverage_path)
        coverage_dir = File.join(coverage_path, "parallel_tests_#{test_num}")

        reports_dir << coverage_dir if File.directory?(coverage_dir)
      end

      coverage_merger.merge(reports_dir)

      ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      elapsed = RSpecTracer::TimeFormatter.format_time(ending - starting)

      RSpecTracer.logger.debug "RSpec tracer merged parallel tests coverage reports (took #{elapsed})"
    end

    def write_parallel_tests_coverage_report
      return unless parallel_tests_executed? && !simplecov?

      starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      coverage_path = File.dirname(RSpecTracer.coverage_path)
      file_name = File.join(coverage_path, 'coverage.json')
      coverage_writer = RSpecTracer::CoverageWriter.new(file_name, coverage_merger)

      coverage_writer.write_report

      ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      coverage_writer.print_stats(ending - starting)
    end

    def purge_parallel_tests_reports
      return unless parallel_tests_executed?

      1.upto(ENV['PARALLEL_TEST_GROUPS'].to_i) do |test_num|
        [RSpecTracer.cache_path, RSpecTracer.coverage_path, RSpecTracer.report_path].each do |path|
          FileUtils.rm_rf(File.join(File.dirname(path), "parallel_tests_#{test_num}"))
        end
      end
    end

    def parallel_tests_executed?
      return false unless parallel_tests? && parallel_tests_last_process?

      ParallelTests.wait_for_other_processes_to_finish

      true
    end

    def parallel_tests_last_process?
      return false unless parallel_tests?

      max_test_num = 0

      File.open(RSpecTracer.lock_file, 'r') do |f|
        f.flock(File::LOCK_SH)

        max_test_num = f.read.to_i
      end

      ENV['TEST_ENV_NUMBER'].to_i == max_test_num
    end
  end
end
