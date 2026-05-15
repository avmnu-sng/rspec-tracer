# frozen_string_literal: true

require_relative 'snapshot'

module RSpecTracer
  module Storage
    # Lazy-reading view returned by `JsonBackend#load_graph`. Presents
    # the same field surface as `Storage::Snapshot` but defers the disk
    # read + deserialization for each field until the caller touches it.
    #
    # Rationale: on a large cache (100 MB+), eager-reading every file
    # at setup dominates warm-run startup (issue #17). Engine
    # at setup touches 10/15 fields; reporters never touch the previous
    # snapshot; third-party tooling often reads one or two. The 3-5
    # fields the Engine does NOT touch at setup (duplicate_examples,
    # reverse_dependency, env_dependency; examples_coverage is deferred
    # to finalize per the seed refactor) save their full disk+parse
    # cost for every run.
    #
    # Duck-types `Snapshot`: every Struct member becomes a method here,
    # `respond_to?` returns true for each, `to_h` materializes the
    # whole thing. Callers doing `prev.send(field)` or `prev.field`
    # work unchanged.
    #
    # Thread-safety: the memoization Hash is not guarded. Engine is
    # single-threaded per run; parallel_tests workers each own their
    # own LazySnapshot instance. If a future caller reads fields from
    # multiple threads, wrap with a Monitor at construct time.
    class LazySnapshot
      LAZY_FIELDS = (Snapshot.members - %i[schema_version run_id]).freeze

      attr_reader :schema_version, :run_id

      def initialize(schema_version:, run_id:, reader:)
        @schema_version = schema_version
        @run_id = run_id
        @reader = reader
        @loaded = {}
      end

      LAZY_FIELDS.each do |field|
        define_method(field) do
          return @loaded[field] if @loaded.key?(field)

          @loaded[field] = @reader.read(field)
        end
      end

      # Hash view matching `Struct#to_h` so callers composing snapshots
      # (merge pipelines, reporter helpers) get the familiar shape.
      # Forces every field to materialize, so only call this when the
      # full cache is genuinely required.
      def to_h
        Snapshot.members.to_h { |m| [m, public_send(m)] }
      end

      # Materialize a full eager Snapshot. Use when an API requires the
      # Struct type (Merger input, backends that accept Snapshot on
      # save). Reads every field.
      def to_snapshot
        Snapshot.new(**to_h)
      end
    end
  end
end
