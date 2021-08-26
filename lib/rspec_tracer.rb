# frozen_string_literal: true

require 'English'

require 'digest/md5'
require 'docile'
require 'fileutils'
require 'forwardable'
require 'json'
require 'pry'
require 'set'

require_relative 'rspec_tracer/configuration'
RSpecTracer.extend RSpecTracer::Configuration

require_relative 'rspec_tracer/coverage_reporter'
require_relative 'rspec_tracer/defaults'
require_relative 'rspec_tracer/example'
require_relative 'rspec_tracer/html_reporter/reporter'
require_relative 'rspec_tracer/rspec_reporter'
require_relative 'rspec_tracer/rspec_runner'
require_relative 'rspec_tracer/ruby_coverage'
require_relative 'rspec_tracer/runner'
require_relative 'rspec_tracer/source_file'
require_relative 'rspec_tracer/version'

module RSpecTracer
  class << self
    attr_accessor :running, :pid

    def start(&block)
      RSpecTracer.running = false
      RSpecTracer.pid = Process.pid

      puts 'Started RSpec tracer'

      configure(&block) if block

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

      [to_run, groups.to_a]
    end
    # rubocop:enable Metrics/AbcSize

    def at_exit_behavior
      return unless RSpecTracer.pid == Process.pid && RSpecTracer.running

      run_exit_tasks
    end

    def start_example_trace
      trace_point.enable if trace_example?
    end

    def stop_example_trace(success)
      return unless trace_example?

      trace_point.disable

      unless success
        @traced_files = Set.new

        return
      end

      @trace_example = false
    end

    def runner
      return @runner if defined?(@runner)
    end

    def coverage_reporter
      return @coverage_reporter if defined?(@coverage_reporter)
    end

    def trace_point
      return @trace_point if defined?(@trace_point)
    end

    def traced_files
      return @traced_files if defined?(@traced_files)
    end

    def trace_example?
      defined?(@trace_example) ? @trace_example : false
    end

    def simplecov?
      return @simplecov if defined?(@simplecov)
    end

    private

    def initial_setup
      unless setup_rspec
        puts 'Could not find a running RSpec process'

        return
      end

      setup_coverage
      setup_trace_point

      @runner = RSpecTracer::Runner.new
      @coverage_reporter = RSpecTracer::CoverageReporter.new
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

      if simplecov?
        # rubocop:disable Lint/EmptyBlock
        SimpleCov.at_exit {}
        # rubocop:enable Lint/EmptyBlock
      else
        require 'coverage'

        ::Coverage.start
      end
    end

    def setup_trace_point
      @trace_example = true
      @traced_files = Set.new

      @trace_point = TracePoint.new(:call) do |tp|
        RSpecTracer.traced_files << tp.path if tp.path.start_with?(RSpecTracer.root)
      end
    end

    def run_exit_tasks
      generate_reports

      simplecov? ? run_simplecov_exit_task : run_coverage_exit_task
    ensure
      RSpecTracer.running = false
    end

    def generate_reports
      puts 'RSpec tracer is generating reports'

      generate_tracer_reports
      generate_coverage_reports
      runner.generate_report
      RSpecTracer::HTMLReporter::Reporter.new.generate_report
    end

    def generate_tracer_reports
      runner.register_deleted_examples
      runner.register_dependency(coverage_reporter.examples_coverage)
      runner.register_untraced_dependency(@traced_files)
    end

    def generate_coverage_reports
      coverage_reporter.generate_final_examples_coverage
      coverage_reporter.merge_coverage(runner.generate_missed_coverage)
      runner.register_examples_coverage(coverage_reporter.examples_coverage)
    end

    def run_simplecov_exit_task
      coverage_clazz = ::Coverage.singleton_class
      clazz = RSpecTracer::RubyCoverage
      coverage_clazz.prepend(clazz) unless coverage_clazz.ancestors.include?(clazz)

      puts 'SimpleCov will now generate coverage report (<3 RSpec tracer)'

      SimpleCov.result.format!
    end

    def run_coverage_exit_task
      coverage_reporter.generate_final_coverage

      file_name = File.join(RSpecTracer.coverage_path, 'coverage.json')

      write_coverage_report(file_name)
      print_coverage_stats(file_name)
    end

    def write_coverage_report(file_name)
      report = {
        RSpecTracer: {
          coverage: coverage_reporter.coverage,
          timestamp: Time.now.utc.to_i
        }
      }

      File.write(file_name, JSON.pretty_generate(report))
    end

    def print_coverage_stats(file_name)
      stat = coverage_reporter.coverage_stat

      puts <<-REPORT.strip.gsub(/\s+/, ' ')
        Coverage report generated for RSpecTracer to #{file_name}. #{stat[:covered_lines]}
        / #{stat[:total_lines]} LOC (#{stat[:covered_percent]}%) covered
      REPORT
    end
  end
end
