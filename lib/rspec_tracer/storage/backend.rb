# frozen_string_literal: true

module RSpecTracer
  # Internal Storage — see {RSpecTracer} for the user-facing surface.
  # @api private
  module Storage
    # Protocol every storage backend must satisfy. JsonBackend is the
    # default; SqliteBackend is an opt-in alternative on MRI. The
    # `spec/contracts/storage_backend.rb` shared-examples group asserts
    # the full contract on every implementation.
    #
    # Rationale for the method set (from ARCHITECTURE.md, Contracts
    # between layers):
    #   - `load_graph(schema_version:)` returns `Snapshot` or `nil`.
    #     `nil` means "no cache, or schema mismatch." Never raises on
    #     corruption - the backend's job is to normalize malformed
    #     inputs into nil + a log line.
    #   - `save_graph(snapshot, schema_version:)` persists the graph.
    #     Either every file lands or none do (atomic via
    #     transactional_save).
    #   - `last_run_id` returns the identifier of the most recent
    #     successful save, or `nil` if no cache exists.
    #   - `transactional_save(&block)` runs the block with
    #     single-writer semantics and commits on clean exit; on any
    #     raise, the pre-block state is preserved.
    #   - `clear!` removes everything the backend owns.
    #
    # This module is intentionally documentation-only - it does not
    # define stubs that raise NotImplementedError, because mutant
    # would flag every `raise` as an alive mutation with no way to
    # kill it. The shared-examples contract is the real gate.
    #
    # @example Registering a custom storage backend
    #   class MyBackend
    #     def load_graph(schema_version:); end
    #     def save_graph(snapshot, schema_version:); end
    #     def last_run_id; end
    #     def transactional_save(&block); yield; end
    #     def clear!; end
    #   end
    #
    #   RSpecTracer.configure do
    #     storage_backend MyBackend.new
    #   end
    module Backend
      # Internal constant.
      # @api private
      REQUIRED_METHODS = %i[
        load_graph
        save_graph
        last_run_id
        transactional_save
        clear!
      ].freeze

      # Verifies a candidate object satisfies the backend protocol.
      # Used by {RSpecTracer::Configuration#storage_backend} to gate
      # custom-backend registration at config-load time.
      #
      # @param backend [Object] candidate backend instance
      # @return [Boolean] true if every {REQUIRED_METHODS} entry is
      #   responded to
      def self.conforms?(backend)
        REQUIRED_METHODS.all? { |m| backend.respond_to?(m) }
      end

      # Construct the configured storage backend instance. Single
      # source of truth for the json/sqlite dispatch + sqlite-gem-
      # missing graceful fallback to :json, used by both
      # {RSpecTracer::Engine} (runtime) and the
      # {RSpecTracer::CLI::CacheInfo} / {RSpecTracer::CLI::Explain}
      # sub-commands (post-run inspection). Pre-refactor, the
      # dispatch lived only on Engine and the CLI sub-commands
      # hardcoded the JsonBackend on-disk layout — so
      # `bin/rspec-tracer cache:info` / `explain` reported "no
      # last_run.json" even when `storage_backend :sqlite` had
      # persisted a working cache.
      #
      # @param cache_path [String] root cache directory.
      # @param configuration [Object] anything responding to the
      #   `storage_backend` / `storage_backend_opts` /
      #   `cache_retention_local_count` / `cache_size_warn_*` /
      #   `logger` accessors (defaults to the {RSpecTracer}
      #   top-level module).
      # @return [Object] a backend instance satisfying {REQUIRED_METHODS}.
      def self.build(cache_path:, configuration: RSpecTracer)
        case configuration.storage_backend
        when :sqlite
          build_sqlite(cache_path: cache_path, configuration: configuration)
        else
          build_json(cache_path: cache_path, configuration: configuration)
        end
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.build_json(cache_path:, configuration:)
        require_relative 'json_backend'
        JsonBackend.new(
          cache_path: cache_path,
          logger: configuration.logger,
          retention_local_count: configuration.cache_retention_local_count,
          warn_per_file_mb: configuration.cache_size_warn_per_file_mb,
          warn_total_mb: configuration.cache_size_warn_total_mb,
          serializer: configuration.storage_backend_opts[:serializer] || :json
        )
      end

      # Internal helper for the tracer pipeline.
      # @api private
      def self.build_sqlite(cache_path:, configuration:)
        require_relative 'sqlite_backend'
        SqliteBackend.new(cache_path: cache_path, logger: configuration.logger)
      rescue SqliteBackend::SqliteBackendError => e
        configuration.logger.warn(
          "rspec-tracer: sqlite backend unavailable (#{e.message}); falling back to :json"
        )
        build_json(cache_path: cache_path, configuration: configuration)
      end
    end
  end
end
