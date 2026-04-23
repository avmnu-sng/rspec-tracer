# frozen_string_literal: true

module RSpecTracer
  class CoverageMerger
    attr_reader :coverage

    def initialize
      @coverage = {}
    end

    def merge(reports_dir)
      return if RSpecTracer.simplecov?

      reports_dir.each do |report_dir|
        next unless File.directory?(report_dir)

        raw = File.read("#{report_dir}/coverage.json", encoding: 'UTF-8')
        cache_coverage = JSON.parse(raw)['RSpecTracer']['coverage']

        cache_coverage.each_pair do |file_name, line_coverage|
          unless @coverage.key?(file_name)
            @coverage[file_name] = line_coverage

            next
          end

          merge_line_coverage(file_name, line_coverage)
        end
      end
    end

    private

    def merge_line_coverage(file_name, line_coverage)
      line_coverage.each_with_index do |strength, line_number|
        next unless strength && @coverage[file_name][line_number]

        @coverage[file_name][line_number] += strength
      end
    end
  end
end
