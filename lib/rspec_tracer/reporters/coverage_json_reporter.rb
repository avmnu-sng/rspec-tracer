# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'set'

require_relative 'base'
require_relative '../line_stub'

module RSpecTracer
  # Internal Reporters — see {RSpecTracer} for the user-facing surface.
  # @api private
  module Reporters
    # Single owner of `coverage.json` emission in 2.0. Replaces the
    # legacy CoverageReporter + CoverageWriter + CoverageMerger +
    # RubyCoverage quartet that 1.x carried. Output shape preserved byte-for-byte
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
    # behavior + the integration matrix convention.
    #
    # Parallel_tests: per-worker emit happens through the Registry
    # like every other reporter (each worker writes its own
    # coverage.json under the per-worker coverage_path). The elected
    # worker calls `merge_parallel` from `RSpec::ParallelTests` to
    # union the per-worker files into the top-level coverage.json.
    class CoverageJsonReporter < Base
      # Internal constant.
      # @api private
      FILENAME = 'coverage.json'

      # Concrete implementation of {RSpecTracer::Reporters::Base#generate}.
      # Builds the cumulative coverage payload and writes `coverage.json`
      # under {#report_dir}, except when SimpleCov owns the run (in which
      # case the SimpleCov interop shim takes over).
      #
      # @return [String, nil] absolute path of the written file, or nil
      #   when the run wrote nothing (engine missing / SimpleCov interop).
      def generate
        return nil unless RSpecTracer.engine
        return install_simplecov_interop if RSpecTracer.simplecov?

        coverage = build_coverage
        write_coverage_json(coverage)
        log_stats(coverage)
        target_path
      end

      # Coverage emission fires unconditionally - even when no examples
      # ran, 1.x writes coverage.json with whatever boot-time peek_result
      # returned (plus filter + stub). Override Base#no_op? so the
      # parent's "snapshot has zero examples" early-return doesn't gate
      # this emitter.
      def no_op?
        false
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

      # Internal helper for the tracer pipeline.
      # @api private
      def self.merge_line_arrays(into, from)
        from.each_with_index do |strength, idx|
          next if strength.nil? || into[idx].nil?

          into[idx] += strength
        end
      end
      private_class_method :merge_line_arrays

      private

      # Internal method on the tracer pipeline.
      # @api private
      def build_coverage
        coverage = engine.coverage_adapter.peek_unfiltered
        accumulate_skipped(coverage)
        finalize_coverage_files(coverage)
      end

      # Shape-agnostic skipped-coverage accumulator. The `coverage`
      # hash carries one of two per-file shapes interchangeably:
      #
      #   - `Array<Integer|nil>`        (lines-only — peek_unfiltered;
      #                                  the user-facing `coverage.json`
      #                                  contract)
      #   - `{ lines: Array, branches: Hash }`
      #                                 (hash-mode — peek_unfiltered_full;
      #                                  what SimpleCov needs when branch
      #                                  coverage is enabled)
      #
      # Both callers (`build_coverage` writing coverage.json,
      # `install_simplecov_interop` feeding SimpleCov.result) share
      # this one accumulator; the per-shape mechanics are isolated in
      # `ensure_mutable_lines`. Hash-mode entries keep their
      # `:branches` sub-hash unchanged (this method only touches
      # lines); array-mode entries are mutated in place. New entries
      # synthesised for files Coverage didn't observe go in as Array
      # (line stubs have no branches to preserve).
      def accumulate_skipped(coverage)
        skipped_ids = engine.registry.ids_with_status(:skipped)
        return coverage if skipped_ids.empty?

        engine.merge_skipped_coverage(skipped_ids).each do |file_path, line_map|
          line_arr = ensure_mutable_lines(coverage, file_path)
          line_map.each do |line_number, strength|
            idx = line_number.to_i
            line_arr[idx] = (line_arr[idx] || 0) + strength
          end
        end
        coverage
      end

      # Returns the mutable `Array<Integer|nil>` view for
      # `coverage[file_path]` we can write per-line strengths into,
      # rewriting `coverage[file_path]` in-place when a dup or stub
      # was needed. `Coverage.peek_result` returns frozen line arrays
      # on Ruby 3.2+; dup-on-write so subsequent writes share the
      # mutable copy.
      #
      #   nil           → install line_stub (Array shape; new entry
      #                    has no branches to preserve).
      #   Hash{lines:,} → if `:lines` is frozen / nil, replace the
      #                    Hash entry with one carrying a fresh /
      #                    dup'd lines array + the original branches.
      #   Array         → if frozen, dup + replace; else mutate in
      #                    place.
      def ensure_mutable_lines(coverage, file_path)
        existing = coverage[file_path]

        case existing
        when nil
          stub = line_stub(file_path)
          coverage[file_path] = stub
          stub
        when ::Hash
          line_arr = existing[:lines]
          return line_arr if line_arr && !line_arr.frozen?

          line_arr = line_arr ? line_arr.dup : line_stub(file_path)
          coverage[file_path] = { lines: line_arr, branches: existing[:branches] || {} }
          line_arr
        else
          return existing unless existing.frozen?

          dup = existing.dup
          coverage[file_path] = dup
          dup
        end
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

      # Internal method on the tracer pipeline.
      # @api private
      def file_name_for(file_path)
        prefix = "#{RSpecTracer.root}/"
        return file_path unless file_path.start_with?(prefix)

        file_path.sub(/\A#{Regexp.escape(RSpecTracer.root)}/, '')
      end

      # Internal method on the tracer pipeline.
      # @api private
      def write_coverage_json(coverage)
        path = target_path
        FileUtils.mkdir_p(File.dirname(path))
        payload = { RSpecTracer: { coverage: coverage, timestamp: Time.now.utc.to_i } }
        File.write(path, JSON.pretty_generate(payload), encoding: 'UTF-8')
      end

      # Internal method on the tracer pipeline.
      # @api private
      def target_path
        File.join(RSpecTracer.coverage_path, FILENAME)
      end

      # Internal method on the tracer pipeline.
      # @api private
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

      # SimpleCov-branch coverage payload skips coverage_filters +
      # line_stub. 1.x parity: when SimpleCov is loaded, the legacy
      # CoverageReporter.coverage exposed via the RubyCoverage shim
      # is the raw peek + skipped-merge accumulator, NOT the
      # generate_final_coverage post-filter view (the legacy
      # `simplecov? ? run_simplecov_exit_task : run_coverage_exit_task`
      # branch only ran generate_final_coverage on the non-SimpleCov
      # side). Preserving this shape keeps SimpleCov's at_exit
      # result-merge seeing whatever it was tracking minus rspec-
      # tracer's narrow filters.
      #
      # `peek_unfiltered_full` preserves Coverage's full
      # `{lines:, branches:}` hash shape verbatim (vs `peek_unfiltered`
      # which reduces hash-mode entries to `:lines` only for the
      # user-facing `coverage.json` Array<Integer|nil> contract).
      # SimpleCov's branch report needs the branches sub-hash;
      # silently stripping them here was the pre-PR-#165 bug that
      # made every dogfooded suite report `Branch Coverage: 0/0`
      # under `enable_coverage :branch`.
      #
      # `accumulate_skipped` is shape-agnostic (handles both
      # hash-mode and array-mode entries; preserves `:branches`
      # untouched on hash-mode dup-on-write), so we hand it the full
      # peek directly without any view-extraction round-trip. Empty
      # skipped registry → it early-returns + nothing reallocates;
      # non-empty → only the per-skipped-file line arrays get dup'd.
      # Either way, no per-call O(N files) allocation.
      def install_simplecov_interop
        coverage = engine.coverage_adapter.peek_unfiltered_full
        accumulate_skipped(coverage)
        SimpleCovInterop.install(coverage)
        nil
      end

      # Inner module preserving 1.x's RubyCoverage shim contract. When
      # SimpleCov calls `::Coverage.result` at its at_exit time, this
      # prepended `result` method returns rspec-tracer's filtered
      # cumulative coverage so SimpleCov's result-merge sees exactly
      # what rspec-tracer saw. Matches the 1.x behavior the
      # integration matrix relies on.
      module SimpleCovInterop
        class << self
          # Internal attribute.
          # @api private
          attr_accessor :coverage
        end

        # Internal helper for the tracer pipeline.
        # @api private
        def self.install(coverage)
          self.coverage = coverage
          klass = ::Coverage.singleton_class
          klass.prepend(self) unless klass.ancestors.include?(self)
        end

        # Internal method on the tracer pipeline.
        # @api private
        def result
          SimpleCovInterop.coverage
        end
      end
    end
  end
end
