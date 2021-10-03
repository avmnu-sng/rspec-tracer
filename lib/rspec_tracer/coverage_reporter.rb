# frozen_string_literal: true

module RSpecTracer
  class CoverageReporter
    COVERAGE_MODE = {
      array: 'array',
      hash: 'hash'
    }.freeze

    attr_reader :mode, :coverage, :coverage_stat, :examples_coverage

    def initialize
      @mode = if !RSpecTracer.simplecov? || ::Coverage.peek_result.first.last.is_a?(Array)
                COVERAGE_MODE[:array]
              else
                COVERAGE_MODE[:hash]
              end

      @examples_coverage = Hash.new do |examples, example_id|
        examples[example_id] = Hash.new do |files, file_path|
          files[file_path] = {}
        end
      end
    end

    def record_coverage
      @coverage = peek_coverage
    end

    def compute_diff(example_id)
      peek_coverage.each_pair do |file_path, current_stats|
        unless @coverage.key?(file_path)
          missing_file_diff_coverage(example_id, file_path, current_stats)

          next
        end

        next if current_stats == @coverage[file_path]

        existing_file_diff_coverage(example_id, file_path, current_stats)
      end
    end

    def generate_final_examples_coverage
      filtered_files = Set.new

      @examples_coverage.each_key do |example_id|
        @examples_coverage[example_id].select! do |file_path|
          next false if filtered_files.include?(file_path)

          file_name = RSpecTracer::SourceFile.file_name(file_path)

          if RSpecTracer.coverage_filters.any? { |filter| filter.match?(file_name: file_name) }
            filtered_files << file_path

            false
          else
            true
          end
        end
      end
    end

    def merge_coverage(missed_coverage)
      record_coverage

      missed_coverage.each_pair do |file_path, line_coverage|
        line_coverage_dup = if @coverage.key?(file_path)
                              @coverage[file_path].dup
                            else
                              line_stub(file_path)
                            end

        line_coverage.each_pair do |line_number, strength|
          line_coverage_dup[line_number.to_i] += strength
        end

        @coverage[file_path] = line_coverage_dup.freeze
      end
    end

    def generate_final_coverage
      return if @coverage_stat

      all_files = final_coverage_files
      @coverage = @coverage.slice(*all_files)

      all_files.each do |file_path|
        @coverage[file_path] ||= line_stub(file_path).freeze
      end

      generate_final_coverage_stat
    end

    private

    def existing_file_diff_coverage(example_id, file_path, coverage_stats)
      coverage_stats.zip(@coverage[file_path])
        .each_with_index do |(c_stat, p_stat), line_number|
          next if c_stat.nil? || p_stat.nil? || c_stat == p_stat

          @examples_coverage[example_id][file_path][line_number] = c_stat - p_stat
        end
    end

    def missing_file_diff_coverage(example_id, file_path, coverage_stats)
      coverage_stats.each_with_index do |stat, line_number|
        next if stat.nil? || stat.zero?

        @examples_coverage[example_id][file_path][line_number] = stat
      end
    end

    def final_coverage_files
      all_files = @coverage.keys.to_set

      if RSpecTracer.coverage_tracked_files
        tracked_files = Dir[RSpecTracer.coverage_tracked_files].map do |file_name|
          RSpecTracer::SourceFile.file_path(file_name)
        end

        all_files |= tracked_files
      end

      all_files.select! do |file_path|
        file_name = RSpecTracer::SourceFile.file_name(file_path)

        RSpecTracer.coverage_filters.none? { |filter| filter.match?(file_name: file_name) }
      end

      all_files.sort
    end

    def generate_final_coverage_stat
      total_loc = 0
      covered_loc = 0

      @coverage.each_pair do |_file_path, line_coverage|
        line_coverage.each do |strength|
          next if strength.nil?

          total_loc += 1
          covered_loc += 1 if strength.positive?
        end
      end

      @coverage_stat = {
        total_lines: total_loc,
        covered_lines: covered_loc,
        missed_lines: total_loc - covered_loc,
        covered_percent: 0.0
      }

      return if total_loc.zero?

      @coverage_stat[:covered_percent] = (100.0 * covered_loc / total_loc).round(2)
    end

    def peek_coverage
      data = ::Coverage.peek_result.select do |file_path, _|
        file_path.start_with?(RSpecTracer.root)
      end

      return data if @mode == COVERAGE_MODE[:array]

      data.transform_values { |stats| stats[:lines] }
    end

    def line_stub(file_path)
      case RUBY_ENGINE
      when 'ruby'
        ruby_line_stub(file_path)
      when 'jruby'
        jruby_line_stub(file_path)
      end
    end

    def ruby_line_stub(file_path)
      lines = File.foreach(file_path).map { nil }
      iseqs = [::RubyVM::InstructionSequence.compile_file(file_path)]

      until iseqs.empty?
        iseq = iseqs.pop

        iseq.trace_points.each { |line_number, type| lines[line_number - 1] = 0 if type == :line }
        iseq.each_child { |child| iseqs << child }
      end

      lines
    end

    # rubocop:disable Metrics/AbcSize
    def jruby_line_stub(file_path)
      lines = File.foreach(file_path).map { nil }
      root_node = ::JRuby.parse(File.read(file_path))

      visitor = org.jruby.ast.visitor.NodeVisitor.impl do |_name, node|
        if node.newline?
          if node.respond_to?(:position)
            lines[node.position.line] = 0
          else
            lines[node.line] = 0
          end
        end

        node.child_nodes.each { |child| child&.accept(visitor) }
      end

      root_node.accept(visitor)

      lines
    end
    # rubocop:enable Metrics/AbcSize
  end
end
