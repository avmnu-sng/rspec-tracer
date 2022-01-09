# frozen_string_literal: true

module RSpecTracer
  class CoverageWriter
    def initialize(file_name, reporter)
      @file_name = file_name
      @reporter = reporter
    end

    def write_report
      report = {
        RSpecTracer: {
          coverage: @reporter.coverage,
          timestamp: Time.now.utc.to_i
        }
      }

      File.write(@file_name, JSON.pretty_generate(report))
    end

    def print_stats(elapsed_time)
      starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      total, covered, percent = coverage_stats

      ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      elapsed = RSpecTracer::TimeFormatter.format_time((ending - starting) + elapsed_time)

      RSpecTracer.logger.info <<-STATS.strip.gsub(/\s+/, ' ')
        Coverage report generated for RSpecTracer to #{@file_name}.
        #{covered} / #{total} LOC (#{percent}%) covered (took #{elapsed})
      STATS
    end

    private

    def coverage_stats
      total_loc = 0
      covered_loc = 0
      covered_percent = 0.0

      @reporter.coverage.each_pair do |_file_path, line_coverage|
        line_coverage.each do |strength|
          next if strength.nil?

          total_loc += 1
          covered_loc += 1 if strength.positive?
        end
      end

      return [total_loc, covered_loc, covered_percent] if total_loc.zero?

      covered_percent = (100.0 * covered_loc / total_loc).round(2)

      [total_loc, covered_loc, covered_percent]
    end
  end
end
