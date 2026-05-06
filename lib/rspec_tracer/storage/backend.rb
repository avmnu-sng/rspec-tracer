# frozen_string_literal: true

module RSpecTracer
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
    end
  end
end
