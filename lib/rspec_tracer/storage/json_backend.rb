# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'set'

require_relative 'backend'
require_relative 'schema'
require_relative 'snapshot'

module RSpecTracer
  module Storage
    # JSON-on-disk storage backend. 1.x shipped this layout without a
    # formal contract; 2.0 treats the FILENAMES list below as the
    # authoritative user-facing surface.
    #
    # External tooling (CI cache keys, debug scripts, report
    # renderers) may reference these exact filenames, so additions or
    # removals are breaking changes. The shared-examples contract in
    # `spec/contracts/storage_backend.rb` enforces the list.
    #
    # Commit point: `last_run.json` is written last via tmp + rename.
    # If any of the 11 per-run files fails to write, `last_run.json`
    # stays pointed at the previous successful run and the partially-
    # written run-id directory is orphaned (harmless; `clear!` reaps
    # it). Readers that see `last_run.json` therefore see a complete
    # snapshot.
    #
    # Concurrency: an exclusive flock on a sentinel file
    # (`.rspec_tracer.lock` under cache_path) serializes writers.
    # Readers do not take the lock - `last_run.json`'s atomic rename
    # is their consistency model.
    #
    # Corruption policy: `load_graph` never raises. Missing files,
    # malformed JSON, wrong schema, binary-garbage input all yield
    # `nil` + an info log. This is the invariant the fuzz spec
    # asserts across 1000 iterations.
    #
    # Encoding: every read and write passes `encoding: 'UTF-8'`.
    # This fixes the M3.1-flagged `Encoding::InvalidByteSequenceError`
    # that bit the dogfood path when an example title contained a
    # non-ASCII byte on a US-ASCII-defaulted filesystem.
    class JsonBackend
      # boot_set.json lands at the end of the list - additive w.r.t.
      # 1.x and v2 readers that walked this enumeration. It carries
      # the project's transitive boot-load set (schema_version 3).
      # wsi_snapshot.json (M4.3) persists the WholeSuiteInvalidators
      # digest_snapshot so warm runs can tell whether Gemfile.lock /
      # .ruby-version / .rspec-tracer / tracer-gem identity changed
      # since the previous run. Without it, warm runs always saw a
      # nil previous and treated every run as a cold first run.
      # Missing file deserializes to `{}` so pre-M4.3 caches still
      # load - the fallback path fires one full re-run (safe).
      FILENAMES = %w[
        all_examples.json
        duplicate_examples.json
        interrupted_examples.json
        flaky_examples.json
        failed_examples.json
        pending_examples.json
        skipped_examples.json
        all_files.json
        dependency.json
        reverse_dependency.json
        examples_coverage.json
        boot_set.json
        wsi_snapshot.json
      ].freeze

      LAST_RUN_FILENAME = 'last_run.json'
      LOCK_FILENAME = '.rspec_tracer.lock'
      ENCODING = 'UTF-8'

      # Field groups for the shape-reconstruction in build_snapshot and
      # write_run_files. The big lists are the price of preserving 1.x's
      # per-field serialization (symbolize-inner-keys, set-from-array,
      # hash-of-set). Grouping them keeps both reader and writer data-
      # driven instead of spelled out row-by-row.
      ID_SET_FIELDS = %w[
        interrupted_examples flaky_examples failed_examples pending_examples skipped_examples
      ].freeze
      HASH_FIELDS = %w[all_examples duplicate_examples all_files examples_coverage boot_set wsi_snapshot].freeze
      DEPENDENCY_FIELDS = %w[dependency reverse_dependency].freeze
      SYMBOLIZED_FIELDS = %w[all_examples all_files].freeze
      # Fields that round-trip as a plain Hash on both sides - no
      # key/value transformation. examples_coverage (1.x) preserved
      # string keys; boot_set (M3.7) + wsi_snapshot (M4.3) are simple
      # name/path => digest maps.
      PLAIN_HASH_FIELDS = %w[examples_coverage boot_set wsi_snapshot].freeze

      attr_reader :cache_path

      def initialize(cache_path:, logger: nil)
        @cache_path = File.expand_path(cache_path)
        @logger = logger
      end

      def last_run_id
        manifest = read_last_run_manifest
        return nil unless manifest.is_a?(Hash)

        run_id = manifest['run_id']
        return nil if run_id.nil? || run_id.to_s.empty?

        run_id
      end

      def load_graph(schema_version:)
        manifest = read_last_run_manifest
        return nil unless manifest.is_a?(Hash)

        stored = manifest['schema_version']
        unless Schema.supported?(stored) && stored == schema_version
          info("schema_version mismatch (stored=#{stored.inspect}, expected=#{schema_version}); cold run")
          return nil
        end

        run_id = manifest['run_id']
        return nil if run_id.nil? || run_id.to_s.empty?

        dir = File.join(@cache_path, run_id)
        return nil unless File.directory?(dir)

        build_snapshot(schema_version: stored, run_id: run_id, dir: dir)
      rescue StandardError => e
        info("failed to load cache: #{e.class}: #{e.message}; cold run")
        nil
      end

      def save_graph(snapshot, schema_version:)
        raise ArgumentError, 'snapshot must not be nil' if snapshot.nil?

        unless Schema.supported?(schema_version)
          raise ArgumentError, "unsupported schema_version: #{schema_version.inspect}"
        end

        run_id = snapshot.run_id
        raise ArgumentError, 'snapshot.run_id must be a non-empty string' if run_id.nil? || run_id.to_s.empty?

        transactional_save do
          dir = File.join(@cache_path, run_id)
          FileUtils.mkdir_p(dir)
          write_run_files(dir, snapshot)
          write_last_run_atomic(schema_version: schema_version, run_id: run_id)
        end

        snapshot
      end

      def transactional_save(&block)
        raise ArgumentError, 'block required' unless block

        FileUtils.mkdir_p(@cache_path)
        File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        end
      end

      def clear!
        return unless File.directory?(@cache_path)

        FileUtils.rm_rf(@cache_path)
      end

      private

      def last_run_path
        File.join(@cache_path, LAST_RUN_FILENAME)
      end

      def lock_path
        File.join(@cache_path, LOCK_FILENAME)
      end

      def read_last_run_manifest
        return nil unless File.file?(last_run_path)

        read_json(last_run_path)
      rescue StandardError
        nil
      end

      def read_json(path)
        contents = File.read(path, encoding: ENCODING)
        JSON.parse(contents)
      end

      def write_json_atomic(path, data)
        tmp_path = "#{path}.tmp.#{Process.pid}.#{rand(1_000_000)}"
        File.write(tmp_path, JSON.pretty_generate(data), encoding: ENCODING)
        File.rename(tmp_path, path)
      ensure
        File.delete(tmp_path) if tmp_path && File.file?(tmp_path)
      end

      def write_run_files(dir, snapshot)
        HASH_FIELDS.each { |f| write_run_field(dir, f, snapshot.send(f) || {}) }
        ID_SET_FIELDS.each { |f| write_run_field(dir, f, serialize_id_set(snapshot.send(f))) }
        DEPENDENCY_FIELDS.each { |f| write_run_field(dir, f, serialize_dependency(snapshot.send(f))) }
      end

      def write_run_field(dir, name, payload)
        write_json_atomic(File.join(dir, "#{name}.json"), payload)
      end

      def write_last_run_atomic(schema_version:, run_id:)
        manifest = { 'schema_version' => schema_version, 'run_id' => run_id, 'timestamp' => Time.now.utc.iso8601 }
        write_json_atomic(last_run_path, manifest)
      end

      # Field-by-field shape reconstruction. Each field is decoded by
      # whichever deserializer round-trips its write-side serializer.
      # The big dispatch is the price of preserving 1.x's idiosyncratic
      # symbolize-inner-keys + set-from-array rules.
      def build_snapshot(schema_version:, run_id:, dir:)
        fields = { schema_version: schema_version, run_id: run_id }
        SYMBOLIZED_FIELDS.each { |f| fields[f.to_sym] = deserialize_symbolized(read_run_file(dir, "#{f}.json")) }
        fields[:duplicate_examples] = deserialize_dupe_examples(read_run_file(dir, 'duplicate_examples.json'))
        ID_SET_FIELDS.each { |f| fields[f.to_sym] = deserialize_id_set(read_run_file(dir, "#{f}.json")) }
        DEPENDENCY_FIELDS.each { |f| fields[f.to_sym] = deserialize_dependency(read_run_file(dir, "#{f}.json")) }
        PLAIN_HASH_FIELDS.each { |f| fields[f.to_sym] = deserialize_plain_hash(read_run_file(dir, "#{f}.json")) }
        Snapshot.new(**fields)
      end

      # Plain-hash round-trip: JSON.parse returns nil on failure, and
      # a valid-but-wrong-shape file would otherwise poison the
      # Snapshot field. Treat anything non-Hash as the empty default.
      def deserialize_plain_hash(raw)
        raw.is_a?(Hash) ? raw : {}
      end

      def read_run_file(dir, name)
        path = File.join(dir, name)
        return nil unless File.file?(path)

        read_json(path)
      rescue StandardError
        nil
      end

      # Sorted Array on disk, Set in memory - matches 1.x report_writer.
      def serialize_id_set(collection)
        return [] if collection.nil?

        collection.to_a.sort
      end

      def deserialize_id_set(raw)
        return Set.new unless raw.is_a?(Array)

        raw.to_set
      end

      # dependency / reverse_dependency: Hash[id => Set<path>] in
      # memory, Hash[id => Array<path>] on disk.
      def serialize_dependency(collection)
        return {} if collection.nil?

        collection.transform_values { |paths| Array(paths) }
      end

      def deserialize_dependency(raw)
        return {} unless raw.is_a?(Hash)

        raw.transform_values { |paths| Array(paths).to_set }
      end

      # all_examples / all_files: inner hashes whose keys 1.x
      # symbolizes after parse.
      def deserialize_symbolized(raw)
        return {} unless raw.is_a?(Hash)

        raw.transform_values do |inner|
          inner.is_a?(Hash) ? inner.transform_keys(&:to_sym) : inner
        end
      end

      # duplicate_examples: Hash[id => Array<Hash>]; each inner hash's
      # keys symbolized post-parse.
      def deserialize_dupe_examples(raw)
        return {} unless raw.is_a?(Hash)

        raw.transform_values do |list|
          next list unless list.is_a?(Array)

          list.map { |entry| entry.is_a?(Hash) ? entry.transform_keys(&:to_sym) : entry }
        end
      end

      def info(message)
        @logger&.info(message)
      end
    end
  end
end
