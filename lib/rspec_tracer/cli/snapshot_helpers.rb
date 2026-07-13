# frozen_string_literal: true

require 'rspec_tracer/storage/backend'
require 'rspec_tracer/storage/json_backend'
require 'rspec_tracer/storage/schema'
require 'rspec_tracer/storage/sqlite_backend' if RUBY_ENGINE == 'ruby'

module RSpecTracer
  # Internal CLI -- see {RSpecTracer} for the user-facing surface.
  # @api private
  module CLI
    # Shared plumbing for the snapshot-reading sub-commands (Explain,
    # BlastRadius): help-flag detection, backend-agnostic snapshot
    # loading with uniform degradation messages, and String/Symbol-
    # tolerant metadata lookups. Extracted so the two commands cannot
    # drift apart on message wording or cache-shape tolerance.
    # @api private
    module SnapshotHelpers
      # @param args [Array<String>] sub-command args (flags removed
      #   by the caller where applicable)
      # @return [Boolean] true when the sub-command should print its
      #   help text instead of executing
      def self.help_requested?(args)
        args.empty? || args.include?('-h') || args.include?('--help')
      end

      # Resolve the persisted snapshot through the configured storage
      # backend ({RSpecTracer::Storage::Backend.build}), so
      # `storage_backend :sqlite` resolves the latest run from the
      # meta table instead of the JsonBackend-only `last_run.json`.
      #
      # @param cache_path [String] root cache directory
      # @param command [String] sub-command name used as the message
      #   prefix (e.g. `explain`, `blast-radius`)
      # @param stderr [IO]
      # @return [Array(Object, Object), nil] `[snapshot, backend]` on
      #   success; nil (after printing a one-line explanation) when no
      #   run has been recorded yet or the cache schema is
      #   incompatible
      def self.load_snapshot(cache_path, command:, stderr:)
        backend = Storage::Backend.build(cache_path: cache_path, configuration: RSpecTracer)
        run_id = backend.last_run_id
        if run_id.nil? || run_id.to_s.empty?
          stderr.puts "#{command}: no cache yet at #{cache_path} -- run rspec first"
          return nil
        end

        snapshot = backend.load_graph(schema_version: Storage::Schema::CURRENT)
        if snapshot.nil?
          stderr.puts "#{command}: cache at #{cache_path} is incompatible with this rspec-tracer; " \
                      'next rspec run is cold'
          return nil
        end

        [snapshot, backend]
      end

      # Whether the backend persists the per-run filter decisions
      # (`filtered_examples` / `skipped_examples`). JsonBackend does;
      # SqliteBackend deliberately does not (its `dispatch_read`
      # returns `{}` for those fields). Callers use this to attribute
      # an empty decision set honestly: on a persisting backend it
      # means "no decision was recorded for this id" (cold run, or the
      # id was not part of the last run), NOT a backend limitation.
      #
      # @param backend [Object] a {RSpecTracer::Storage::Backend.build}
      #   product
      # @return [Boolean]
      def self.filter_decisions_persisted?(backend)
        backend.is_a?(Storage::JsonBackend)
      end

      # Look up a key from a Hash, tolerating both String and Symbol
      # storage. Snapshot Hashes round-tripped through JSON yield
      # String keys; the post-#182 msgpack serializer preserves
      # Symbol keys end-to-end, so callers can't assume either shape.
      def self.fetch_meta(meta, *keys)
        keys.each do |k|
          v = meta[k]
          return v unless v.nil?

          sym_value = meta[k.to_sym]
          return sym_value unless sym_value.nil?
        end
        nil
      end

      # Look up a nested key from a Hash, tolerating both String and
      # Symbol storage at each level. See {.fetch_meta} for rationale.
      def self.dig_meta(meta, *keys)
        keys.reduce(meta) do |acc, k|
          break nil if acc.nil? || !acc.is_a?(::Hash)

          acc[k] || acc[k.to_sym]
        end
      end

      # The example's rerun location from persisted all_examples meta,
      # preferring the rerun_* fields the reporter records.
      #
      # @param meta [Hash] one all_examples entry
      # @return [Array(Object, Object)] `[file, line]`; either element
      #   may be nil when the meta is missing the field
      def self.example_location(meta)
        [
          fetch_meta(meta, 'rerun_file_name', 'file_name'),
          fetch_meta(meta, 'rerun_line_number', 'line_number')
        ]
      end

      # @param meta [Hash] one all_examples entry
      # @return [String, nil] the example's description, or nil when
      #   the meta is missing both description fields
      def self.example_description(meta)
        fetch_meta(meta, 'full_description', 'description')
      end
    end
  end
end
