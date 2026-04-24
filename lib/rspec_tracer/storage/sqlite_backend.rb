# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'set'
require 'time'

require_relative 'backend'
require_relative 'lazy_snapshot'
require_relative 'schema'
require_relative 'snapshot'

module RSpecTracer
  module Storage
    # SQLite-on-disk storage backend. Single file
    # `cache_path/rspec_tracer.sqlite3` with a normalized 9-table
    # schema so a warm run can materialize only the rows a given
    # field needs (Filter.select hits ~50-500 example_ids out of
    # millions, JsonBackend eagerly read the whole map). Breaks
    # the RAM-scales-with-cache-size curve that JsonBackend cannot
    # escape without a different on-disk shape.
    #
    # MRI-only. The `sqlite3` gem targets MRI's C API; JRuby's
    # `jdbc-sqlite3` has a different API that this backend does
    # not target in 2.0. Users who select `:sqlite` on JRuby
    # (or on MRI without the `sqlite3` gem in their Gemfile) see
    # the construct raise `SqliteBackendError`, which the Engine's
    # backend dispatch converts to a warn + cold-run fallback.
    #
    # No multi-run history. SqliteBackend stores only the latest
    # run; save_graph full-replaces every table inside a single
    # `BEGIN IMMEDIATE` transaction. JsonBackend's
    # `cache_retention_local_count` is a no-op here. Users who
    # need rollback history stay on `:json`.
    #
    # `journal_mode = MEMORY` so SQLite's WAL / SHM sidecars do not
    # leak into the user-facing `rspec_tracer_cache/` directory
    # (USER_FACING_SURFACE.md section 6 locks the layout; sidecars
    # would surprise debug scripts that walk the dir expecting only
    # documented files).
    # rubocop:disable Metrics/ClassLength
    class SqliteBackend
      # Raised when the sqlite3 gem cannot be loaded. Engine's
      # build_storage_backend dispatch rescues + falls back to
      # `:json` with a warn line - same optional-dep posture as
      # RedisBackend (M7.2) uses for the redis gem.
      class SqliteBackendError < StandardError; end

      DB_FILENAME = 'rspec_tracer.sqlite3'
      JOURNAL_MODE_SQL = 'PRAGMA journal_mode = MEMORY'
      SYNCHRONOUS_SQL = 'PRAGMA synchronous = NORMAL'

      STATUS_FIELDS = {
        interrupted_examples: 'interrupted',
        flaky_examples: 'flaky',
        failed_examples: 'failed',
        pending_examples: 'pending',
        skipped_examples: 'skipped'
      }.freeze

      DIGEST_MAP_KINDS = {
        boot_set: 'boot',
        wsi_snapshot: 'wsi',
        env_snapshot: 'env'
      }.freeze

      # Mirrors FIELD_FILENAMES from JsonBackend - the set of Snapshot
      # fields a LazySnapshot reader may ask about. Used by
      # SqliteFieldReader to reject unknown fields before hitting the
      # DB. Kept in step with Snapshot.members minus the envelope.
      READABLE_FIELDS = (
        %i[all_examples duplicate_examples all_files dependency
           reverse_dependency examples_coverage env_dependency] +
          STATUS_FIELDS.keys + DIGEST_MAP_KINDS.keys
      ).freeze

      # Binds a SqliteBackend so LazySnapshot readers can dispatch
      # one field at a time without threading a connection through.
      class SqliteFieldReader
        def initialize(backend:)
          @backend = backend
        end

        def read(field)
          @backend.read_field(field)
        end
      end

      attr_reader :cache_path

      def initialize(cache_path:, logger: nil)
        @cache_path = File.expand_path(cache_path)
        @logger = logger
        load_sqlite_driver!
      end

      def last_run_id
        with_connection do |db|
          row = db.get_first_row('SELECT run_id FROM meta LIMIT 1')
          run_id = row&.first
          return nil if run_id.nil? || run_id.to_s.empty?

          run_id
        end
      rescue StandardError
        nil
      end

      def load_graph(schema_version:)
        with_connection do |db|
          return nil unless meta_table_exists?(db)

          row = db.get_first_row('SELECT schema_version, run_id FROM meta LIMIT 1')
          return nil if row.nil?

          stored_sv, run_id = row
          unless Schema.supported?(stored_sv) && stored_sv == schema_version
            info("schema_version mismatch (stored=#{stored_sv.inspect}, expected=#{schema_version}); cold run")
            return nil
          end
          return nil if run_id.nil? || run_id.to_s.empty?

          LazySnapshot.new(
            schema_version: stored_sv, run_id: run_id,
            reader: SqliteFieldReader.new(backend: self)
          )
        end
      rescue StandardError => e
        info("failed to load sqlite cache: #{e.class}: #{e.message}; cold run")
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
          db = @active_db
          write_all_tables(db, snapshot, schema_version: schema_version)
        end

        snapshot
      end

      def clear!
        return unless File.directory?(@cache_path)

        FileUtils.rm_rf(@cache_path)
      end

      def transactional_save(&block)
        raise ArgumentError, 'block required' unless block

        FileUtils.mkdir_p(@cache_path)
        with_write_connection do |db|
          @active_db = db
          db.transaction(:immediate, &block)
        ensure
          @active_db = nil
        end
      end

      # Read one field on behalf of a LazySnapshot. Missing table or
      # empty result returns the per-field empty default (Set for
      # id-set fields, {} for hashes) so partial caches behave
      # identically to JsonBackend under the same conditions.
      # ArgumentError on an unknown field is a programmer mistake and
      # propagates; the StandardError rescue is only for wire / I/O
      # failures on the DB itself.
      def read_field(field)
        raise ArgumentError, "unknown snapshot field: #{field.inspect}" unless READABLE_FIELDS.include?(field)

        begin
          with_connection { |db| dispatch_read(db, field) }
        rescue StandardError => e
          info("sqlite read_field(#{field.inspect}) failed: #{e.class}: #{e.message}; returning empty default")
          empty_default_for(field)
        end
      end

      private

      def db_path
        File.join(@cache_path, DB_FILENAME)
      end

      def load_sqlite_driver!
        require 'sqlite3'
      rescue LoadError
        raise SqliteBackendError,
              "sqlite3 gem is not installed; add `gem 'sqlite3'` to your Gemfile " \
              '(MRI only; `~> 1.7` works on Ruby 3.1, `~> 2.0` needs Ruby >= 3.2) ' \
              'or switch to `storage_backend :json`.'
      end

      def with_connection
        return nil unless File.file?(db_path)

        db = ::SQLite3::Database.new(db_path)
        configure_connection(db)
        yield db
      ensure
        db&.close
      end

      def with_write_connection
        FileUtils.mkdir_p(@cache_path)
        db = ::SQLite3::Database.new(db_path)
        configure_connection(db)
        ensure_schema!(db)
        yield db
      ensure
        db&.close
      end

      def configure_connection(db)
        db.execute(JOURNAL_MODE_SQL)
        db.execute(SYNCHRONOUS_SQL)
      end

      def meta_table_exists?(db)
        row = db.get_first_row(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'meta' LIMIT 1"
        )
        !row.nil?
      end

      def ensure_schema!(db)
        SCHEMA_STATEMENTS.each { |sql| db.execute(sql) }
      end

      SCHEMA_STATEMENTS = [
        'CREATE TABLE IF NOT EXISTS meta (' \
        'schema_version INTEGER NOT NULL, ' \
        'run_id TEXT NOT NULL, ' \
        'timestamp TEXT NOT NULL' \
        ')',
        'CREATE TABLE IF NOT EXISTS examples (' \
        'example_id TEXT PRIMARY KEY, ' \
        'metadata_json BLOB NOT NULL' \
        ')',
        'CREATE TABLE IF NOT EXISTS duplicate_examples (' \
        'example_id TEXT NOT NULL, ' \
        'idx INTEGER NOT NULL, ' \
        'entry_json BLOB NOT NULL, ' \
        'PRIMARY KEY (example_id, idx)' \
        ')',
        'CREATE TABLE IF NOT EXISTS all_files (' \
        'file_name TEXT PRIMARY KEY, ' \
        'file_path TEXT NOT NULL, ' \
        'digest TEXT NOT NULL' \
        ')',
        'CREATE TABLE IF NOT EXISTS dependency (' \
        'example_id TEXT NOT NULL, ' \
        'file_name TEXT NOT NULL, ' \
        'PRIMARY KEY (example_id, file_name)' \
        ')',
        'CREATE INDEX IF NOT EXISTS idx_dependency_file_name ON dependency(file_name)',
        'CREATE TABLE IF NOT EXISTS examples_coverage (' \
        'example_id TEXT NOT NULL, ' \
        'file_path TEXT NOT NULL, ' \
        'line_key INTEGER NOT NULL, ' \
        'strength INTEGER NOT NULL, ' \
        'PRIMARY KEY (example_id, file_path, line_key)' \
        ')',
        'CREATE TABLE IF NOT EXISTS env_dependency (' \
        'example_id TEXT NOT NULL, ' \
        'env_name TEXT NOT NULL, ' \
        'PRIMARY KEY (example_id, env_name)' \
        ')',
        'CREATE TABLE IF NOT EXISTS digest_maps (' \
        'kind TEXT NOT NULL, ' \
        'key TEXT NOT NULL, ' \
        'digest TEXT NOT NULL, ' \
        'PRIMARY KEY (kind, key)' \
        ')',
        'CREATE TABLE IF NOT EXISTS id_sets (' \
        'status TEXT NOT NULL, ' \
        'example_id TEXT NOT NULL, ' \
        'PRIMARY KEY (status, example_id)' \
        ')'
      ].freeze
      private_constant :SCHEMA_STATEMENTS

      TRUNCATE_TABLES = %w[
        meta examples duplicate_examples all_files dependency
        examples_coverage env_dependency digest_maps id_sets
      ].freeze
      private_constant :TRUNCATE_TABLES

      def write_all_tables(db, snapshot, schema_version:)
        TRUNCATE_TABLES.each { |t| db.execute("DELETE FROM #{t}") }

        db.execute(
          'INSERT INTO meta (schema_version, run_id, timestamp) VALUES (?, ?, ?)',
          [schema_version, snapshot.run_id, Time.now.utc.iso8601]
        )

        write_example_rows(db, snapshot)
        write_graph_rows(db, snapshot)
        write_grouped_rows(db, snapshot)
      end

      def write_example_rows(db, snapshot)
        insert_examples(db, snapshot.all_examples || {})
        insert_duplicate_examples(db, snapshot.duplicate_examples || {})
        insert_all_files(db, snapshot.all_files || {})
      end

      def write_graph_rows(db, snapshot)
        insert_dependency(db, snapshot.dependency || {})
        insert_examples_coverage(db, snapshot.examples_coverage || {})
        insert_env_dependency(db, snapshot.env_dependency || {})
      end

      def write_grouped_rows(db, snapshot)
        DIGEST_MAP_KINDS.each do |field, kind|
          insert_digest_map(db, kind, snapshot.send(field) || {})
        end
        STATUS_FIELDS.each do |field, status|
          insert_id_set(db, status, snapshot.send(field) || Set.new)
        end
      end

      def insert_examples(db, examples)
        sql = 'INSERT INTO examples (example_id, metadata_json) VALUES (?, ?)'
        examples.each { |id, meta| db.execute(sql, [id.to_s, ::JSON.generate(meta || {})]) }
      end

      def insert_duplicate_examples(db, dupes)
        sql = 'INSERT INTO duplicate_examples (example_id, idx, entry_json) VALUES (?, ?, ?)'
        dupes.each do |id, list|
          Array(list).each_with_index do |entry, idx|
            db.execute(sql, [id.to_s, idx, ::JSON.generate(entry || {})])
          end
        end
      end

      def insert_all_files(db, all_files)
        sql = 'INSERT INTO all_files (file_name, file_path, digest) VALUES (?, ?, ?)'
        all_files.each do |file_name, meta|
          next unless meta.is_a?(Hash)

          db.execute(sql, [file_name.to_s, fetch_hash(meta, :file_path).to_s, fetch_hash(meta, :digest).to_s])
        end
      end

      def insert_dependency(db, dependency)
        sql = 'INSERT INTO dependency (example_id, file_name) VALUES (?, ?)'
        dependency.each do |id, file_names|
          Array(file_names).each { |name| db.execute(sql, [id.to_s, name.to_s]) }
        end
      end

      def insert_examples_coverage(db, coverage)
        sql = 'INSERT INTO examples_coverage (example_id, file_path, line_key, strength) VALUES (?, ?, ?, ?)'
        coverage.each do |id, per_file|
          next unless per_file.is_a?(Hash)

          per_file.each do |file_path, lines|
            iterate_line_entries(lines) do |line_key, strength|
              db.execute(sql, [id.to_s, file_path.to_s, line_key, strength])
            end
          end
        end
      end

      # Accept both Hash[line_key => strength] (engine output) and
      # Array[strength_or_nil] (raw ::Coverage.result shape) so specs
      # that construct snapshots directly with Array values still
      # round-trip. The canonical on-disk shape is (line_key_int,
      # strength_int) rows; nil strengths drop out.
      def iterate_line_entries(lines)
        case lines
        when Hash
          lines.each { |line_key, strength| yield(line_key.to_i, strength.to_i) if strength }
        when Array
          lines.each_with_index { |strength, idx| yield(idx, strength.to_i) if strength }
        end
      end

      def insert_env_dependency(db, env_dep)
        sql = 'INSERT INTO env_dependency (example_id, env_name) VALUES (?, ?)'
        env_dep.each do |id, names|
          Array(names).each { |name| db.execute(sql, [id.to_s, name.to_s]) }
        end
      end

      def insert_digest_map(db, kind, map)
        sql = 'INSERT INTO digest_maps (kind, key, digest) VALUES (?, ?, ?)'
        map.each { |k, digest| db.execute(sql, [kind, k.to_s, digest.to_s]) }
      end

      def insert_id_set(db, status, ids)
        sql = 'INSERT INTO id_sets (status, example_id) VALUES (?, ?)'
        Array(ids.to_a).each { |id| db.execute(sql, [status, id.to_s]) }
      end

      def dispatch_read(db, field)
        case field
        when :all_examples then read_all_examples(db)
        when :duplicate_examples then read_duplicate_examples(db)
        when :all_files         then read_all_files(db)
        when :dependency        then read_dependency(db)
        when :reverse_dependency then read_reverse_dependency(db)
        when :examples_coverage then read_examples_coverage(db)
        when :env_dependency    then read_env_dependency(db)
        else                    dispatch_read_grouped(db, field)
        end
      end

      def dispatch_read_grouped(db, field)
        return read_id_set(db, STATUS_FIELDS.fetch(field)) if STATUS_FIELDS.key?(field)

        read_digest_map(db, DIGEST_MAP_KINDS.fetch(field))
      end

      def read_all_examples(db)
        result = {}
        db.execute('SELECT example_id, metadata_json FROM examples').each do |row|
          id, meta_json = row
          result[id] = decode_hash_with_sym_keys(meta_json)
        end
        result
      end

      def read_duplicate_examples(db)
        result = Hash.new { |h, k| h[k] = [] }
        rows = db.execute('SELECT example_id, idx, entry_json FROM duplicate_examples ORDER BY example_id, idx')
        rows.each do |row|
          id, _idx, entry_json = row
          result[id] << decode_hash_with_sym_keys(entry_json)
        end
        result.each_with_object({}) { |(k, v), h| h[k] = v } # strip default_proc
      end

      def read_all_files(db)
        result = {}
        db.execute('SELECT file_name, file_path, digest FROM all_files').each do |row|
          name, path, digest = row
          result[name] = { file_name: name, file_path: path, digest: digest }
        end
        result
      end

      def read_dependency(db)
        result = Hash.new { |h, k| h[k] = Set.new }
        db.execute('SELECT example_id, file_name FROM dependency').each do |row|
          id, name = row
          result[id] << name
        end
        result.each_with_object({}) { |(k, v), h| h[k] = v }
      end

      def read_reverse_dependency(db)
        result = Hash.new { |h, k| h[k] = Set.new }
        db.execute('SELECT file_name, example_id FROM dependency').each do |row|
          name, id = row
          result[name] << id
        end
        result.each_with_object({}) { |(k, v), h| h[k] = v }
      end

      def read_examples_coverage(db)
        result = {}
        rows = db.execute('SELECT example_id, file_path, line_key, strength FROM examples_coverage')
        rows.each do |row|
          id, path, line_key, strength = row
          result[id] ||= {}
          (result[id][path] ||= {})[line_key.to_i] = strength.to_i
        end
        result
      end

      def read_env_dependency(db)
        result = Hash.new { |h, k| h[k] = [] }
        rows = db.execute('SELECT example_id, env_name FROM env_dependency ORDER BY example_id, env_name')
        rows.each do |row|
          id, name = row
          result[id] << name
        end
        result.each_with_object({}) { |(k, v), h| h[k] = v }
      end

      def read_id_set(db, status)
        result = Set.new
        db.execute('SELECT example_id FROM id_sets WHERE status = ?', [status]).each do |row|
          result << row.first
        end
        result
      end

      def read_digest_map(db, kind)
        result = {}
        db.execute('SELECT key, digest FROM digest_maps WHERE kind = ?', [kind]).each do |row|
          key, digest = row
          result[key] = digest
        end
        result
      end

      def empty_default_for(field)
        return Set.new if STATUS_FIELDS.key?(field)

        {}
      end

      def decode_hash_with_sym_keys(json_bytes)
        parsed = ::JSON.parse(json_bytes)
        return parsed unless parsed.is_a?(Hash)

        parsed.transform_keys(&:to_sym)
      end

      def fetch_hash(hash, key)
        return hash[key] if hash.key?(key)

        hash[key.to_s]
      end

      def info(message)
        @logger&.info(message)
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
