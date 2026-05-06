# frozen_string_literal: true

require 'coverage'
require 'set'

require_relative 'file_digest'
require_relative 'input'

module RSpecTracer
  # Internal Tracker — see {RSpecTracer} for the user-facing surface.
  # @api private
  module Tracker
    # Wraps Ruby's built-in ::Coverage module. The first observer in
    # the 2.0 tracker pipeline -- ingests the per-file line-coverage
    # bitmap that MRI/JRuby maintain natively, normalizes the two
    # possible shapes (array vs SimpleCov-style hash) and emits
    # Tracker::Input values for the files touched between two peeks.
    #
    # All state lives on the instance; no reads from RSpecTracer.*.
    # Pass root, filters, and mode at construction time.
    #
    # Content digest is SHA256 hex (see Input's file-level comment).
    # Changing the algorithm is a storage schema_version bump.
    class CoverageAdapter
      # ::Coverage.peek_result returns one of two shapes:
      #   :array -- { path => [hit_counts | nil, ...] }           (default)
      #   :hash  -- { path => { lines: [...], branches: {...} } } (SimpleCov
      #                                                           with branch
      #                                                           coverage)
      # :auto detects on the first peek by sniffing a value's type.
      MODES = %i[auto array hash].freeze

      # Internal attribute.
      # @api private
      attr_reader :root, :filters, :mode

      # Internal method on the tracer pipeline.
      # @api private
      def initialize(root:, filters: [], mode: :auto)
        raise ArgumentError, "invalid mode: #{mode.inspect}, allowed: #{MODES}" \
          unless MODES.include?(mode)

        @root = File.expand_path(root)
        @root_prefix = "#{@root}/"
        @filters = filters
        @mode = mode
      end

      # Snapshot of the current coverage state: { absolute_path =>
      # Array<Integer|nil> } for files under project root that survive
      # the user filter. Hash-mode input is reduced to its :lines
      # component -- 2.0 ignores branch coverage (same as 1.x; noted in
      # the upgrade docs).
      def peek
        peek_normalized { |path| filtered?(path) }
      end

      # Same shape as #peek but only filters by `@root_prefix` -- skips
      # the user `filters` filter. The coverage.json emitter
      # (`Reporters::CoverageJsonReporter`) calls this at finalize to
      # capture cumulative coverage matching legacy semantics: 1.x's
      # CoverageReporter#peek_coverage applied no `filters` filter at
      # peek time and let `coverage_filters` do the final exclusion.
      # Routing the emitter's finalize peek through this method keeps
      # the lib/-wide `::Coverage.peek_result` call-site count at 3
      # (one per file: this adapter, rspec/installation, and
      # tracker/loaded_files_tracker) instead of adding a fourth.
      def peek_unfiltered
        peek_normalized { false }
      end

      # Same root-prefix scoping as #peek_unfiltered, but preserves
      # Coverage's full per-file shape (Hash `{ lines: [...], branches:
      # {...} }` in hash mode; Array<Integer|nil> in array mode) instead
      # of reducing hash entries to their `:lines` component.
      #
      # Lone caller is the SimpleCov interop shim
      # (`Reporters::CoverageJsonReporter::SimpleCovInterop`): when
      # SimpleCov has `enable_coverage :branch`, Coverage runs in hash
      # mode and the prepended `Coverage.result` MUST hand back the
      # branches sub-hash so SimpleCov's branch-coverage report path
      # has data to render. The legacy `peek_unfiltered` strips
      # branches because the user-facing `coverage.json` shape is
      # documented as `Array<Integer|nil>` per file (1.x compatibility);
      # do not change `peek_unfiltered` to do otherwise without bumping
      # the storage schema.
      def peek_unfiltered_full
        raw = ::Coverage.peek_result
        @mode = detect_mode(raw) if @mode == :auto

        raw.each_with_object({}) do |(path, stats), acc|
          next unless path.start_with?(@root_prefix)

          acc[path] = stats
        end
      end

      # Pure function: returns Set<Input> for files whose line arrays
      # changed between `before` and `after`. Handles nil line entries
      # (unexecutable lines) correctly -- nil<->nil is not a delta, any
      # other transition is.
      def compute_diff(before, after)
        changed = Set.new
        (before.keys | after.keys).each do |path|
          next unless delta?(before[path], after[path])

          changed << Input.for_file(
            path: path,
            kind: :ruby,
            digest: file_digest(path),
            root: @root
          )
        end
        changed
      end

      private

      # Single owner of the `::Coverage.peek_result` call site for
      # `peek` and `peek_unfiltered`. Skip block decides exclusion;
      # everything that survives gets normalized through the array/hash
      # mode handling.
      def peek_normalized
        raw = ::Coverage.peek_result
        @mode = detect_mode(raw) if @mode == :auto

        raw.each_with_object({}) do |(path, stats), acc|
          next unless path.start_with?(@root_prefix)
          next if yield(path)

          acc[path] = @mode == :hash ? stats[:lines] : stats
        end
      end

      # Internal method on the tracer pipeline.
      # @api private
      def detect_mode(raw)
        return :array if raw.empty?

        raw.each_value.first.is_a?(Hash) ? :hash : :array
      end

      # Internal method on the tracer pipeline.
      # @api private
      def filtered?(path)
        return false if @filters.empty?

        # Legacy filter convention: file_name is root-stripped with
        # leading slash. Keep it so existing .rspec-tracer filter
        # strings/regexes work under the new adapter unchanged.
        file_name = path.sub(@root, '')
        @filters.any? { |f| f.match?(file_name: file_name) }
      end

      # Internal method on the tracer pipeline.
      # @api private
      def delta?(before, after)
        return true if before.nil? || after.nil?
        return true if before.length != after.length

        before.each_with_index do |bv, i|
          return true unless bv == after[i]
        end
        false
      end

      # Internal method on the tracer pipeline.
      # @api private
      def file_digest(path)
        FileDigest.compute(path)
      end
    end
  end
end
