# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'set'

require_relative 'base'
require_relative '../line_stub'

module RSpecTracer
  module Reporters
    # M8.0 owner of `coverage.json` emission. Replaces the legacy
    # CoverageReporter + CoverageWriter + CoverageMerger + RubyCoverage
    # quartet that 1.x carried. Output shape preserved byte-for-byte
    # for downstream consumers (user CI dashboards parse this):
    #
    #   { "RSpecTracer": {
    #       "coverage": { "<absolute_path>": [Integer|nil, ...], ... },
    #       "timestamp": <Integer>
    #   } }
    #
    # Cumulative coverage source: `::Coverage.peek_result` at finalize
    # time, routed through `Tracker::CoverageAdapter#peek_unfiltered`
    # so the lib/-wide peek_result call-site count stays at 3 (one
    # each in coverage_adapter.rb, rspec/installation.rb, and
    # tracker/loaded_files_tracker.rb).
    #
    # Skipped-example contribution: `Engine#merge_skipped_coverage`,
    # which replays 1.x's CoverageReporter algorithm verbatim - per-
    # skipped-example per-line strengths add into the cumulative map.
    #
    # SimpleCov interop: when SimpleCov is loaded, this reporter does
    # NOT write coverage.json. Instead it installs a small inner module
    # via `::Coverage.singleton_class.prepend` so SimpleCov's at_exit
    # result-merge sees rspec-tracer's filtered coverage. Matches 1.x
    # behavior + the M4.3 integration matrix convention.
    #
    # Parallel_tests: per-worker emit happens through the Registry
    # like every other reporter (each worker writes its own
    # coverage.json under the per-worker coverage_path). The elected
    # worker calls `merge_parallel` from `RSpec::ParallelTests` to
    # union the per-worker files into the top-level coverage.json.
    class CoverageJsonReporter < Base
      FILENAME = 'coverage.json'

      def generate
        return nil if no_op?
        return install_simplecov_interop if RSpecTracer.simplecov?

        coverage = build_coverage
        write_coverage_json(coverage)
        log_stats(coverage)
        target_path
      end

      # Class-level rollup for parallel_tests. Unions per-line
      # strengths across the per-worker coverage.json files written by
      # `generate` on each worker, then writes the merged top-level
      # coverage.json. Replaces 1.x's
      # `CoverageMerger.new + CoverageWriter.new(top_path, merger)`.
      def self.merge_parallel(peer_paths:, output_path:, logger: nil)
        merged = {}
        peer_paths.each do |peer|
          path = File.join(peer, FILENAME)
          next unless File.file?(path)

          data = JSON.parse(File.read(path, encoding: 'UTF-8'))
          peer_coverage = data.fetch('RSpecTracer').fetch('coverage')
          peer_coverage.each do |file_path, lines|
            if merged.key?(file_path)
              merge_line_arrays(merged[file_path], lines)
            else
              merged[file_path] = lines.dup
            end
          end
        end

        FileUtils.mkdir_p(File.dirname(output_path))
        payload = { RSpecTracer: { coverage: merged, timestamp: Time.now.utc.to_i } }
        File.write(output_path, JSON.pretty_generate(payload), encoding: 'UTF-8')
        logger&.debug("rspec-tracer: wrote merged coverage.json to #{output_path}")
        output_path
      end

      def self.merge_line_arrays(into, from)
        from.each_with_index do |strength, idx|
          next if strength.nil? || into[idx].nil?

          into[idx] += strength
        end
      end
      private_class_method :merge_line_arrays

      private

      def build_coverage
        coverage = engine.coverage_adapter.peek_unfiltered
        accumulate_skipped(coverage)
        finalize_coverage_files(coverage)
      end

      def accumulate_skipped(coverage)
        skipped_ids = engine.registry.ids_with_status(:skipped)
        return coverage if skipped_ids.empty?

        engine.merge_skipped_coverage(skipped_ids).each do |file_path, line_map|
          existing = coverage[file_path]
          if existing.nil?
            stub = line_stub(file_path)
            coverage[file_path] = stub
            existing = stub
          end
          line_map.each do |line_number, strength|
            idx = line_number.to_i
            existing[idx] = (existing[idx] || 0) + strength
          end
        end
        coverage
      end

      # Apply `coverage_filters` + `coverage_tracked_files` glob; sort
      # the resulting file list (matches legacy CoverageReporter#
      # final_coverage_files at coverage_reporter.rb:113-131) and slice
      # + line-stub missing entries.
      def finalize_coverage_files(coverage)
        all = coverage.keys.to_set

        if RSpecTracer.coverage_tracked_files
          Dir[RSpecTracer.coverage_tracked_files].each do |name|
            all << File.expand_path(name, RSpecTracer.root)
          end
        end

        all.select! do |file_path|
          name = file_name_for(file_path)
          RSpecTracer.coverage_filters.none? { |filter| filter.match?(file_name: name) }
        end

        all.sort.to_h { |file_path| [file_path, coverage[file_path] || line_stub(file_path).freeze] }
      end

      def file_name_for(file_path)
        prefix = "#{RSpecTracer.root}/"
        return file_path unless file_path.start_with?(prefix)

        file_path.sub(/\A#{Regexp.escape(RSpecTracer.root)}/, '')
      end

      def write_coverage_json(coverage)
        path = target_path
        FileUtils.mkdir_p(File.dirname(path))
        payload = { RSpecTracer: { coverage: coverage, timestamp: Time.now.utc.to_i } }
        File.write(path, JSON.pretty_generate(payload), encoding: 'UTF-8')
      end

      def target_path
        File.join(RSpecTracer.coverage_path, FILENAME)
      end

      def log_stats(coverage)
        total = 0
        covered = 0
        coverage.each_value do |lines|
          lines.each do |strength|
            next if strength.nil?

            total += 1
            covered += 1 if strength.positive?
          end
        end
        return if total.zero?

        percent = (100.0 * covered / total).round(2)
        logger&.info(
          "rspec-tracer: coverage #{covered}/#{total} LOC (#{percent}%) -> #{target_path}"
        )
      end

      # Delegates to the top-level RSpecTracer::LineStub which holds
      # the per-engine MRI/JRuby implementations. Kept off the gated
      # path so the JRuby branch (uncoverable on MRI) doesn't fail
      # the 100%-line+branch contract this gated subdir carries.
      def line_stub(file_path)
        RSpecTracer::LineStub.for(file_path)
      end

      def engine
        RSpecTracer.engine
      end

      def install_simplecov_interop
        coverage = build_coverage
        SimpleCovInterop.install(coverage)
        nil
      end

      # Inner module preserving 1.x's RubyCoverage shim contract. When
      # SimpleCov calls `::Coverage.result` at its at_exit time, this
      # prepended `result` method returns rspec-tracer's filtered
      # cumulative coverage so SimpleCov's result-merge sees exactly
      # what rspec-tracer saw. Matches the 1.x behavior the M4.3
      # integration matrix relies on.
      module SimpleCovInterop
        class << self
          attr_accessor :coverage
        end

        def self.install(coverage)
          self.coverage = coverage
          klass = ::Coverage.singleton_class
          klass.prepend(self) unless klass.ancestors.include?(self)
        end

        def result
          SimpleCovInterop.coverage
        end
      end
    end
  end
end
