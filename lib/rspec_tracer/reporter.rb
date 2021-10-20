# frozen_string_literal: true

module RSpecTracer
  class Reporter
    attr_reader :all_examples, :interrupted_examples, :duplicate_examples,
                :possibly_flaky_examples, :flaky_examples, :pending_examples,
                :skipped_examples, :failed_examples, :all_files, :modified_files,
                :deleted_files, :dependency, :examples_coverage

    attr_accessor :reverse_dependency, :last_run

    def initialize
      initialize_examples
      initialize_files
      initialize_dependency
      initialize_coverage
    end

    def register_example(example)
      @all_examples[example[:example_id]] = example
      @duplicate_examples[example[:example_id]] << example
    end

    def deregister_duplicate_examples
      @duplicate_examples.select! { |_, examples| examples.count > 1 }

      return if @duplicate_examples.empty?

      @all_examples.reject! { |example_id, _| @duplicate_examples.key?(example_id) }
    end

    def on_example_skipped(example_id)
      @skipped_examples << example_id
    end

    def on_example_passed(example_id, result)
      return if @duplicate_examples.key?(example_id)

      @passed_examples << example_id
      @all_examples[example_id][:execution_result] = formatted_execution_result(result)
    end

    def on_example_failed(example_id, result)
      return if @duplicate_examples.key?(example_id)

      @failed_examples << example_id
      @all_examples[example_id][:execution_result] = formatted_execution_result(result)
    end

    def on_example_pending(example_id, result)
      return if @duplicate_examples.key?(example_id)

      @pending_examples << example_id
      @all_examples[example_id][:execution_result] = formatted_execution_result(result)
    end

    def register_interrupted_examples
      @all_examples.each_pair do |example_id, example|
        next if example.key?(:execution_result)

        @interrupted_examples << example_id
      end

      return if @interrupted_examples.empty?

      puts "RSpec tracer is not processing #{@interrupted_examples.count} interrupted examples"
    end

    def register_deleted_examples(seen_examples)
      @deleted_examples = seen_examples.keys.to_set - (@skipped_examples | @all_examples.keys)
      @deleted_examples -= @interrupted_examples

      @deleted_examples.select! do |example_id|
        example = seen_examples[example_id]

        file_changed?(example[:file_name]) || file_changed?(example[:rerun_file_name])
      end
    end

    def register_possibly_flaky_example(example_id)
      @possibly_flaky_examples << example_id
    end

    def register_flaky_example(example_id)
      @flaky_examples << example_id
    end

    def register_failed_example(example_id)
      @failed_examples << example_id
    end

    def register_pending_example(example_id)
      @pending_examples << example_id
    end

    def duplicate_example?(example_id)
      @duplicate_examples.key?(example_id)
    end

    def example_interrupted?(example_id)
      @interrupted_examples.include?(example_id)
    end

    def example_passed?(example_id)
      @passed_examples.include?(example_id)
    end

    def example_skipped?(example_id)
      @skipped_examples.include?(example_id)
    end

    def example_failed?(example_id)
      @failed_examples.include?(example_id)
    end

    def example_pending?(example_id)
      @pending_examples.include?(example_id)
    end

    def example_deleted?(example_id)
      @deleted_examples.include?(example_id)
    end

    def register_source_file(source_file)
      @all_files[source_file[:file_name]] = source_file
    end

    def on_file_deleted(file_name)
      @deleted_files << file_name
    end

    def on_file_modified(file_name)
      @modified_files << file_name
    end

    def file_deleted?(file_name)
      @deleted_files.include?(file_name)
    end

    def file_modified?(file_name)
      @modified_files.include?(file_name)
    end

    def file_changed?(file_name)
      file_deleted?(file_name) || file_modified?(file_name)
    end

    def register_dependency(example_id, file_name)
      @dependency[example_id] << file_name
    end

    def register_examples_coverage(examples_coverage)
      @examples_coverage = examples_coverage
    end

    private

    def initialize_examples
      @all_examples = {}
      @duplicate_examples = Hash.new { |examples, example_id| examples[example_id] = [] }
      @interrupted_examples = Set.new
      @passed_examples = Set.new
      @possibly_flaky_examples = Set.new
      @flaky_examples = Set.new
      @failed_examples = Set.new
      @skipped_examples = Set.new
      @pending_examples = Set.new
      @deleted_examples = Set.new
    end

    def initialize_files
      @all_files = {}
      @modified_files = Set.new
      @deleted_files = Set.new
    end

    def initialize_dependency
      @dependency = Hash.new { |hash, key| hash[key] = Set.new }
      @reverse_dependency = Hash.new do |examples, file_name|
        examples[file_name] = {
          example_count: 0,
          examples: Hash.new(0)
        }
      end
    end

    def initialize_coverage
      @examples_coverage = Hash.new do |examples, example_id|
        examples[example_id] = Hash.new do |files, file_name|
          files[file_name] = {}
        end
      end
    end

    def formatted_execution_result(result)
      {
        started_at: result.started_at.utc,
        finished_at: result.finished_at.utc,
        run_time: result.run_time,
        status: result.status.to_s
      }
    end
  end
end
