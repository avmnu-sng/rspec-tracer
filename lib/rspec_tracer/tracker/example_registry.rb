# frozen_string_literal: true

require 'set'

module RSpecTracer
  module Tracker
    # Per-example status + metadata registry. The Filter consults the
    # registry to decide which examples always re-run (failed / flaky
    # / pending / interrupted); the registry also owns duplicate
    # detection via RSpec's identity-hash surface (the same hash 1.x
    # uses for `fail_on_duplicates`).
    #
    # M3.5 owns the data structure only. `update_status` is called by
    # M5.1 (RSpec integration hooks) on example-finished events and
    # by signal handlers on interruption; M3.6 passes the registry
    # instance through Tracker.setup. The registry itself has no
    # opinion about where status comes from.
    #
    # Statuses
    # --------
    #   :passed       - completed cleanly
    #   :failed       - example assertion failed
    #   :pending      - RSpec `pending`
    #   :interrupted  - RSpec was killed mid-example (SIGINT / SIGTERM)
    #   :flaky        - passed this run but previously failed (M5.1
    #                   detects via retry semantics)
    #   :skipped      - skipped via `skip` or `:skip` metadata; tracked
    #                   for coverage attribution but NOT auto-re-run
    #
    # `always_re_run_ids` returns the union of {failed, flaky,
    # pending, interrupted} - the 1.x invariant that examples with
    # those statuses run on every subsequent suite regardless of
    # whether their input files changed. `:skipped` is deliberately
    # excluded (matches 1.x `skipped_examples.json` which is written
    # but not added to the re-run set).
    class ExampleRegistry
      STATUSES = %i[passed failed pending interrupted flaky skipped].freeze
      ALWAYS_RE_RUN_STATUSES = %i[failed flaky pending interrupted].freeze

      def initialize
        @examples = {}
        @identity_index = {}
        @duplicates = {}
      end

      # Registers an example id with optional metadata (opaque Hash
      # passed through to Snapshot.all_examples) and optional
      # identity_hash for duplicate detection. First call wins for
      # the identity_hash binding; subsequent calls with the same
      # identity_hash but a different example_id accumulate into
      # `@duplicates` and do not re-bind.
      def register(example_id, metadata: {}, identity_hash: nil)
        @examples[example_id] ||= { metadata: metadata.dup, status: nil }
        track_identity(example_id, identity_hash) if identity_hash
        self
      end

      def update_status(example_id, status)
        raise ArgumentError, "unknown status: #{status.inspect}" unless STATUSES.include?(status)
        raise ArgumentError, "example not registered: #{example_id.inspect}" unless @examples.key?(example_id)

        @examples[example_id][:status] = status
        self
      end

      def status_of(example_id)
        @examples[example_id]&.dig(:status)
      end

      def metadata_of(example_id)
        entry = @examples[example_id]
        return nil if entry.nil?

        entry[:metadata].dup
      end

      def registered?(example_id)
        @examples.key?(example_id)
      end

      def all_example_ids
        @examples.keys.to_set
      end

      def size
        @examples.size
      end

      def ids_with_status(status)
        @examples.each_with_object(Set.new) do |(id, entry), acc|
          acc << id if entry[:status] == status
        end
      end

      def always_re_run_ids
        @examples.each_with_object(Set.new) do |(id, entry), acc|
          acc << id if ALWAYS_RE_RUN_STATUSES.include?(entry[:status])
        end
      end

      # Hash[identity_hash => Array<example_id>] of every collision
      # observed. The array always has >= 2 entries (the first
      # registrant plus every colliding follower).
      def duplicates
        @duplicates.transform_values(&:dup)
      end

      def duplicate?(identity_hash)
        @duplicates.key?(identity_hash)
      end

      private

      def track_identity(example_id, identity_hash)
        existing = @identity_index[identity_hash]
        if existing.nil?
          @identity_index[identity_hash] = example_id
        elsif existing != example_id
          bucket = (@duplicates[identity_hash] ||= [existing])
          bucket << example_id unless bucket.include?(example_id)
        end
      end
    end
  end
end
