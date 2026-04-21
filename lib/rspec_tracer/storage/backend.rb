# frozen_string_literal: true

module RSpecTracer
  module Storage
    # Protocol every storage backend must satisfy. JsonBackend is the
    # only shipping implementation in 2.0; SqliteBackend arrives in
    # M3.8. The `spec/contracts/storage_backend.rb` shared-examples
    # group asserts the full contract on every implementation.
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
    module Backend
      REQUIRED_METHODS = %i[
        load_graph
        save_graph
        last_run_id
        transactional_save
        clear!
      ].freeze

      def self.conforms?(backend)
        REQUIRED_METHODS.all? { |m| backend.respond_to?(m) }
      end
    end
  end
end
