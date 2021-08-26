# frozen_string_literal: true

require 'erb'
require 'time'

module RSpecTracer
  module HTMLReporter
    class Reporter
      attr_reader :last_run, :examples, :examples_dependency, :files_dependency

      def initialize
        @reporter = RSpecTracer.runner.reporter

        format_last_run
        format_examples
        format_examples_dependency
        format_files_dependency
      end

      def generate_report
        Dir[File.join(File.dirname(__FILE__), 'public/*')].each do |path|
          FileUtils.cp_r(path, asset_output_path)
        end

        file_name = File.join(RSpecTracer.report_path, 'index.html')

        File.open(file_name, 'wb') do |file|
          file.puts(template('layout').result(binding))
        end

        puts "RSpecTracer generated HTML report to #{file_name}"
      end

      private

      def format_last_run
        @last_run = @reporter.last_run.slice(
          :actual_count,
          :failed_examples,
          :pending_examples,
          :skipped_examples
        )
      end

      def format_examples
        @examples = {}

        @reporter.all_examples.each_pair do |example_id, example|
          @examples[example_id] = {
            id: example_id,
            description: example[:full_description],
            location: example_location(example[:rerun_file_name], example[:rerun_line_number]),
            status: example[:run_reason] || 'Skipped',
            result: example[:execution_result][:status].capitalize,
            last_run: example_run_local_time(example[:execution_result][:finished_at])
          }
        end
      end

      def example_run_local_time(utc_time)
        case utc_time
        when Time
          utc_time.localtime.strftime('%Y-%m-%d %H:%M:%S')
        when String
          Time.parse(utc_time).localtime.strftime('%Y-%m-%d %H:%M:%S')
        else
          utc_time.inspect
        end
      end

      def format_examples_dependency
        @examples_dependency = []

        @reporter.dependency.each_pair do |example_id, files|
          @examples_dependency << {
            example_id: example_id,
            example: @examples[example_id][:description],
            files_count: files.count,
            files: files.map { |file_name| shortened_file_name(file_name) }.sort.join(', ')
          }
        end
      end

      def format_files_dependency
        @files_dependency = []

        @reporter.reverse_dependency.each_pair do |main_file_name, data|
          short_file_name = shortened_file_name(main_file_name)

          @files_dependency << {
            name: short_file_name,
            example_count: data[:example_count],
            file_count: data[:examples].count,
            files: data[:examples]
              .map { |file_name, count| "#{shortened_file_name(file_name)}: #{count}" }
              .join(', ')
          }
        end
      end

      def example_location(file_name, line_number)
        "#{shortened_file_name(file_name)}:#{line_number}"
      end

      def shortened_file_name(file_name)
        file_name.sub(%r{^/}, '')
      end

      def asset_output_path
        @asset_output_path ||= begin
          asset_output_path = File.join(RSpecTracer.report_path, 'assets', RSpecTracer::VERSION)

          FileUtils.mkdir_p(asset_output_path)

          asset_output_path
        end
      end

      def assets_path(name)
        File.join('./assets', RSpecTracer::VERSION, name)
      end

      def formatted_examples(title, examples)
        title_id = report_container_id(title)
        current_binding = binding

        current_binding.local_variable_set(:title_id, title_id)
        template(title_id).result(current_binding)
      end

      def formatted_examples_dependency(title, examples_dependency)
        title_id = report_container_id(title)
        current_binding = binding

        current_binding.local_variable_set(:title_id, title_id)
        template(title_id).result(current_binding)
      end

      def formatted_files_dependency(title, files_dependency)
        title_id = report_container_id(title)
        current_binding = binding

        current_binding.local_variable_set(:title_id, title_id)
        template(title_id).result(current_binding)
      end

      def report_container_id(title)
        title.gsub(/\s+/, ' ').downcase.tr(' ', '_')
      end

      def template(name)
        ERB.new(File.read(File.join(File.dirname(__FILE__), 'views/', "#{name}.erb")))
      end

      def example_status_css_class(example_status)
        case example_status.split.first
        when 'Failed'
          'red'
        when 'Pending'
          'yellow'
        else
          'blue'
        end
      end

      def example_result_css_class(example_result)
        case example_result
        when 'Passed'
          'green'
        when 'Failed'
          'red'
        when 'Pending'
          'yellow'
        else
          'blue'
        end
      end
    end
  end
end
