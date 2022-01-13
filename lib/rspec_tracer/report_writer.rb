# frozen_string_literal: true

module RSpecTracer
  class ReportWriter
    def initialize(report_dir, reporter)
      @report_dir = report_dir
      @reporter = reporter
    end

    def write_report
      starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      @run_id = Digest::MD5.hexdigest(@reporter.all_examples.keys.sort.to_json)
      @cache_dir = File.join(@report_dir, @run_id)

      FileUtils.mkdir_p(@cache_dir)

      write_all_examples_report
      write_duplicate_examples_report
      write_interrupted_examples_report
      write_flaky_examples_report
      write_failed_examples_report
      write_pending_examples_report
      write_skipped_examples_report
      write_all_files_report
      write_dependency_report
      write_reverse_dependency_report
      write_examples_coverage_report
      write_last_run_report

      ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      elapsed = RSpecTracer::TimeFormatter.format_time(ending - starting)

      RSpecTracer.logger.debug "RSpec tracer reports written to #{@cache_dir} (took #{elapsed})"
    end

    def print_duplicate_examples
      return if @reporter.duplicate_examples.empty?

      total = @reporter.duplicate_examples.sum { |_, examples| examples.count }

      RSpecTracer.logger.error [
        '=' * 80,
        '   IMPORTANT NOTICE -- RSPEC TRACER COULD NOT IDENTIFY SOME EXAMPLES UNIQUELY',
        '=' * 80,
        "RSpec tracer could not uniquely identify the following #{total} examples:"
      ].join("\n")

      justify = ' ' * 2
      nested_justify = justify * 3

      @reporter.duplicate_examples.each_pair do |example_id, examples|
        RSpecTracer.logger.error "#{justify}- Example ID: #{example_id} (#{examples.count} examples)"

        examples.each do |example|
          description = example[:full_description].strip
          file_name = example[:rerun_file_name].sub(%r{^/}, '')
          line_number = example[:rerun_line_number]
          location = "#{file_name}:#{line_number}"

          RSpecTracer.logger.error "#{nested_justify}* #{description} (#{location})"
        end
      end
    end

    private

    def write_all_examples_report
      file_name = File.join(@cache_dir, 'all_examples.json')

      File.write(file_name, JSON.pretty_generate(@reporter.all_examples))
    end

    def write_duplicate_examples_report
      file_name = File.join(@cache_dir, 'duplicate_examples.json')

      File.write(file_name, JSON.pretty_generate(@reporter.duplicate_examples))
    end

    def write_interrupted_examples_report
      file_name = File.join(@cache_dir, 'interrupted_examples.json')

      File.write(file_name, JSON.pretty_generate(@reporter.interrupted_examples.sort.to_a))
    end

    def write_flaky_examples_report
      file_name = File.join(@cache_dir, 'flaky_examples.json')

      File.write(file_name, JSON.pretty_generate(@reporter.flaky_examples.sort.to_a))
    end

    def write_failed_examples_report
      file_name = File.join(@cache_dir, 'failed_examples.json')

      File.write(file_name, JSON.pretty_generate(@reporter.failed_examples.sort.to_a))
    end

    def write_pending_examples_report
      file_name = File.join(@cache_dir, 'pending_examples.json')

      File.write(file_name, JSON.pretty_generate(@reporter.pending_examples.sort.to_a))
    end

    def write_skipped_examples_report
      file_name = File.join(@cache_dir, 'skipped_examples.json')

      File.write(file_name, JSON.pretty_generate(@reporter.skipped_examples.sort.to_a))
    end

    def write_all_files_report
      file_name = File.join(@cache_dir, 'all_files.json')

      File.write(file_name, JSON.pretty_generate(@reporter.all_files))
    end

    def write_dependency_report
      file_name = File.join(@cache_dir, 'dependency.json')

      File.write(file_name, JSON.pretty_generate(@reporter.dependency))
    end

    def write_reverse_dependency_report
      file_name = File.join(@cache_dir, 'reverse_dependency.json')

      File.write(file_name, JSON.pretty_generate(@reporter.reverse_dependency))
    end

    def write_examples_coverage_report
      file_name = File.join(@cache_dir, 'examples_coverage.json')

      File.write(file_name, JSON.pretty_generate(@reporter.examples_coverage))
    end

    def write_last_run_report
      file_name = File.join(@report_dir, 'last_run.json')
      last_run_data = @reporter.last_run.merge(run_id: @run_id, timestamp: Time.now.utc)

      File.write(file_name, JSON.pretty_generate(last_run_data))
    end
  end
end
