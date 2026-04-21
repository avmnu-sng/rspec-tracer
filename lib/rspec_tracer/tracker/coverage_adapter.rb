# frozen_string_literal: true

require 'coverage'
require 'digest'
require 'set'

require_relative 'input'

module RSpecTracer
  module Tracker
    # Wraps Ruby's built-in ::Coverage module. The first observer in
    # the 2.0 tracker pipeline — ingests the per-file line-coverage
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
      #   :array — { path => [hit_counts | nil, ...] }           (default)
      #   :hash  — { path => { lines: [...], branches: {...} } } (SimpleCov
      #                                                           with branch
      #                                                           coverage)
      # :auto detects on the first peek by sniffing a value's type.
      MODES = %i[auto array hash].freeze

      attr_reader :root, :filters, :mode

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
      # component — 2.0 ignores branch coverage (same as 1.x; noted in
      # the upgrade docs).
      def peek
        raw = ::Coverage.peek_result
        @mode = detect_mode(raw) if @mode == :auto

        raw.each_with_object({}) do |(path, stats), acc|
          next unless path.start_with?(@root_prefix)
          next if filtered?(path)

          acc[path] = @mode == :hash ? stats[:lines] : stats
        end
      end

      # Pure function: returns Set<Input> for files whose line arrays
      # changed between `before` and `after`. Handles nil line entries
      # (unexecutable lines) correctly — nil↔nil is not a delta, any
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

      def detect_mode(raw)
        return :array if raw.empty?

        raw.each_value.first.is_a?(Hash) ? :hash : :array
      end

      def filtered?(path)
        return false if @filters.empty?

        # Legacy filter convention: file_name is root-stripped with
        # leading slash. Keep it so existing .rspec-tracer filter
        # strings/regexes work under the new adapter unchanged.
        file_name = path.sub(@root, '')
        @filters.any? { |f| f.match?(file_name: file_name) }
      end

      def delta?(before, after)
        return true if before.nil? || after.nil?
        return true if before.length != after.length

        before.each_with_index do |bv, i|
          return true unless bv == after[i]
        end
        false
      end

      def file_digest(path)
        return nil unless File.file?(path)

        Digest::SHA256.file(path).hexdigest
      rescue SystemCallError
        nil
      end
    end
  end
end
