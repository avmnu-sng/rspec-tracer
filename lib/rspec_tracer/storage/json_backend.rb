# frozen_string_literal: true

require 'digest/md5'
require 'fileutils'
require 'json'
require 'set'
require 'time' # Time#iso8601 for last_run.json timestamp

require_relative 'backend'
require_relative 'lazy_snapshot'
require_relative 'schema'
require_relative 'serializer/json'
require_relative 'serializer/msgpack'
require_relative 'snapshot'

module RSpecTracer
  # Internal Storage — see {RSpecTracer} for the user-facing surface.
  # @api private
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
    # Fixes the `Encoding::InvalidByteSequenceError` that bit the
    # dogfood path when an example title contained a non-ASCII byte on
    # a US-ASCII-defaulted filesystem.
    # rubocop:disable Metrics/ClassLength
    class JsonBackend
      # On-disk filenames under the default `:json` serializer. This
      # is the user-facing surface documented in
      # USER_FACING_SURFACE.md section 6 - external tooling that walks
      # `rspec_tracer_cache/` relies on exactly these names.
      # The `:msgpack` serializer substitutes `.msgpack.gz` for the
      # `.json` suffix (one file per field on disk); the file stems
      # and per-field semantics do not change.
      # boot_set.json lands at the end of the list - additive w.r.t.
      # 1.x and v2 readers that walked this enumeration. It carries
      # the project's transitive boot-load set (schema_version 3).
      # wsi_snapshot.json persists the WholeSuiteInvalidators
      # digest_snapshot so warm runs can tell whether Gemfile.lock /
      # .ruby-version / .rspec-tracer / tracer-gem identity changed
      # since the previous run. Without it, warm runs always saw a
      # nil previous and treated every run as a cold first run.
      # Missing file deserializes to `{}` so older caches still load -
      # the fallback path fires one full re-run (safe).
      # env_snapshot.json persists the `Tracker::EnvSnapshot` digest
      # map for env-var values the per-example `tracks: { env: ... }`
      # DSL declares. Same missing-coerces-to-`{}` fallback as
      # wsi_snapshot - no schema bump.
      # env_dependency.json persists the per-example tracked-env
      # attribution map that reporters need for the Examples Dependency
      # report. Missing file coerces to `{}`; older caches load
      # without a cold re-run.
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
        env_snapshot.json
        env_dependency.json
        cache_hit_reason.json
        filtered_examples.json
      ].freeze

      # Internal constant.
      # @api private
      LAST_RUN_FILENAME = 'last_run.json'
      # Internal constant.
      # @api private
      LOCK_FILENAME = '.rspec_tracer.lock'
      # Internal constant.
      # @api private
      ENCODING = 'UTF-8'

      # Known snapshot field symbols. Derived directly from FIELD_KINDS
      # below (the write-side and read-side shape tables both enumerate
      # the same set, so a divergence would already blow up write
      # paths). Kept as an Array of Symbol so `#read_field` can dispatch
      # without constructing a per-serializer filename table; the
      # filename is computed as "#{field}.#{@serializer.extension}".
      FIELD_NAMES = %i[
        all_examples
        duplicate_examples
        interrupted_examples
        flaky_examples
        failed_examples
        pending_examples
        skipped_examples
        all_files
        dependency
        reverse_dependency
        examples_coverage
        boot_set
        wsi_snapshot
        env_snapshot
        env_dependency
        cache_hit_reason
        filtered_examples
      ].freeze

      # Binds a backend + run directory so `LazySnapshot` readers
      # call exactly one public entry point (`backend.read_field`).
      # Keeping this as a nested class (not a Proc) so mutant can
      # introspect the reader contract.
      class FieldReader
        # Internal method on the tracer pipeline.
        # @api private
        def initialize(backend:, dir:)
          @backend = backend
          @dir = dir
        end

        # Internal method on the tracer pipeline.
        # @api private
        def read(field)
          @backend.read_field(@dir, field)
        end
      end

      # Write-side field groups. Each group dispatches to one
      # serializer (Hash pass-through, Set->sorted Array, or the
      # Hash[id => Set<path>] -> Hash[id => Array<path>] flavor
      # shared by dependency + reverse_dependency). Kept data-driven
      # so a schema_version bump adds one entry instead of a new
      # branch. Read-side uses FIELD_KINDS below.
      ID_SET_FIELDS = %w[
        interrupted_examples flaky_examples failed_examples pending_examples skipped_examples
      ].freeze
      # Internal constant.
      # @api private
      HASH_FIELDS = %w[
        all_examples duplicate_examples all_files examples_coverage
        boot_set wsi_snapshot env_snapshot env_dependency cache_hit_reason
        filtered_examples
      ].freeze
      # Internal constant.
      # @api private
      DEPENDENCY_FIELDS = %w[dependency reverse_dependency].freeze

      # Read-side field -> deserializer-kind map. Drives
      # `decode_field` so the lazy reader looks up one shape
      # per field instead of spelling out a case/when that
      # has to stay in sync with FILENAMES. `:symbolized` =
      # Hash whose inner Hash values get symbolized keys
      # (1.x's all_examples / all_files convention);
      # `:dupe_examples` = same but Array-of-inner-Hash;
      # `:id_set` = Array on disk -> Set in memory;
      # `:dependency` = Hash[id => Array] -> Hash[id => Set];
      # `:plain_hash` = pass-through (examples_coverage, the
      # digest maps, env_dependency).
      FIELD_KINDS = {
        all_examples: :symbolized,
        all_files: :symbolized,
        duplicate_examples: :dupe_examples,
        interrupted_examples: :id_set,
        flaky_examples: :id_set,
        failed_examples: :id_set,
        pending_examples: :id_set,
        skipped_examples: :id_set,
        dependency: :dependency,
        reverse_dependency: :dependency,
        examples_coverage: :plain_hash,
        boot_set: :plain_hash,
        wsi_snapshot: :plain_hash,
        env_snapshot: :plain_hash,
        env_dependency: :plain_hash,
        cache_hit_reason: :plain_hash,
        filtered_examples: :plain_hash
      }.freeze

      # Internal attribute.
      # @api private
      attr_reader :cache_path, :serializer, :serializer_name

      # rubocop:disable Metrics/ParameterLists
      def initialize(cache_path:, logger: nil, retention_local_count: nil,
                     warn_per_file_mb: nil, warn_total_mb: nil, serializer: :json)
        # rubocop:enable Metrics/ParameterLists
        @cache_path = File.expand_path(cache_path)
        @logger = logger
        @retention_local_count = retention_local_count
        @warn_per_file_mb = warn_per_file_mb
        @warn_total_mb = warn_total_mb
        @serializer = resolve_serializer(serializer)
        @serializer_name = serializer
      end

      # Internal method on the tracer pipeline.
      # @api private
      def last_run_id
        manifest = read_last_run_manifest
        return nil unless manifest.is_a?(Hash)

        run_id = manifest['run_id']
        return nil if run_id.nil? || run_id.to_s.empty?

        run_id
      end

      # Internal method on the tracer pipeline.
      # @api private
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

        LazySnapshot.new(
          schema_version: stored, run_id: run_id,
          reader: FieldReader.new(backend: self, dir: dir)
        )
      rescue StandardError => e
        info("failed to load cache: #{e.class}: #{e.message}; cold run")
        nil
      end

      # Read and deserialize one per-run field. Public so
      # `FieldReader` (constructed by `load_graph`) can dispatch.
      # Missing file -> same default value the eager read previously
      # produced (Set.new for ID-set fields, {} for hashes) -
      # preserves the "malformed cache loads gracefully" contract.
      #
      # `deep_intern` runs before the decode so String dedup
      # happens once per on-disk path / example_id regardless of
      # how many times the value appears in the parsed tree.
      # RAM win on large caches is the whole point of this method;
      # see json_backend_spec.rb "string interning" for the
      # measurable assertion.
      def read_field(dir, field)
        raise ArgumentError, "unknown snapshot field: #{field.inspect}" unless FIELD_KINDS.key?(field)

        raw = read_run_file(dir, field_filename(field))
        decode_field(field, deep_intern(raw))
      end

      # Per-serializer on-disk filename for a snapshot field.
      # `:json` -> `all_examples.json`; `:msgpack` ->
      # `all_examples.msgpack.gz`. Public so integration specs /
      # reporters can resolve the expected path without reaching
      # into @serializer.
      def field_filename(field)
        "#{field}.#{@serializer.extension}"
      end

      # Internal method on the tracer pipeline.
      # @api private
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

        maybe_prune_after_save
        maybe_warn_size_budget(run_id)
        snapshot
      end

      # Retain the `keep` most-recently-modified run-id directories
      # under cache_path and delete older ones. Always preserves the
      # run-id that `last_run.json` points at (deleting it would make
      # the next reader cold-run). Returns the count removed. Never
      # raises - a prune failure is logged at warn level and treated
      # as best-effort cleanup, same graceful-degradation contract
      # the remote cache backends use.
      #
      # `keep` nil / non-positive -> no-op. Called automatically from
      # `save_graph` when the backend was constructed with
      # `retention_local_count:`; also exposed via `rake
      # rspec_tracer:cache:gc` for one-off cleanup.
      def prune_run_dirs!(keep:)
        return 0 if keep.nil? || keep <= 0
        return 0 unless File.directory?(@cache_path)

        current = last_run_id
        candidates = collect_run_dirs
        return 0 if candidates.empty?

        _keep, pruned = partition_dirs_to_prune(candidates, keep: keep, current: current)
        pruned.each { |path| FileUtils.rm_rf(path) }
        pruned.size
      rescue StandardError => e
        @logger&.warn("rspec-tracer cache gc: prune failed (#{e.class}: #{e.message})")
        0
      end

      # Internal method on the tracer pipeline.
      # @api private
      def transactional_save(&block)
        raise ArgumentError, 'block required' unless block

        FileUtils.mkdir_p(@cache_path)
        File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        end
      end

      # Internal method on the tracer pipeline.
      # @api private
      def clear!
        return unless File.directory?(@cache_path)

        FileUtils.rm_rf(@cache_path)
      end

      # Merge per-worker snapshots (written to `peer_cache_paths`) into
      # this backend's top-level cache and persist via `save_graph`.
      # Read each peer via `load_graph` so schema + corruption policy
      # (missing files yield nil, malformed JSON logs + returns nil)
      # flows through the same path as a normal load.
      #
      # No peers / every peer nil -> no-op returns nil. Partial peers
      # merge what's available; graceful degradation is the entire
      # point of running this at at_exit time.
      #
      # `schema_version` is passed through so peers saved under a
      # different schema version are rejected without side effects
      # (same semantics as a warm run under a mismatched cache).
      def merge_from_peers(peer_cache_paths, schema_version:)
        peer_snapshots = peer_cache_paths.filter_map do |path|
          self.class.new(cache_path: path, logger: @logger, serializer: @serializer_name)
            .load_graph(schema_version: schema_version)
        end

        return nil if peer_snapshots.empty?

        merged = Merger.call(peer_snapshots, schema_version: schema_version)
        save_graph(merged, schema_version: schema_version)
        merged
      end

      # Stateless snapshot union. parallel_tests partitions spec files
      # across workers, so example IDs are disjoint in practice - the
      # merge collision rules (first-wins for metadata, sum-of-ints for
      # per-line coverage) only fire on collaborating workers that
      # happened to observe the same input file.
      module Merger
        # Internal helper for the tracer pipeline.
        # @api private
        def self.call(snapshots, schema_version:)
          state = empty_state
          snapshots.each { |s| absorb(state, s) }

          state[:reverse_dependency] = reverse_of(state[:dependency])
          state[:run_id] = Digest::MD5.hexdigest(state[:all_examples].keys.sort.to_json)
          state[:cache_hit_reason] = state[:filtered_examples].values.tally

          build_merged_snapshot(state, schema_version: schema_version)
        end

        # Internal helper for the tracer pipeline.
        # @api private
        def self.build_merged_snapshot(state, schema_version:)
          Snapshot.new(
            schema_version: schema_version,
            run_id: state[:run_id],
            all_examples: state[:all_examples],
            duplicate_examples: state[:duplicate_examples],
            interrupted_examples: state[:interrupted_examples],
            flaky_examples: state[:flaky_examples],
            failed_examples: state[:failed_examples],
            pending_examples: state[:pending_examples],
            skipped_examples: state[:skipped_examples],
            all_files: state[:all_files],
            dependency: state[:dependency],
            reverse_dependency: state[:reverse_dependency],
            examples_coverage: state[:examples_coverage],
            boot_set: state[:boot_set],
            wsi_snapshot: state[:wsi_snapshot],
            env_snapshot: state[:env_snapshot],
            env_dependency: state[:env_dependency],
            cache_hit_reason: state[:cache_hit_reason],
            filtered_examples: state[:filtered_examples]
          )
        end

        # Internal helper for the tracer pipeline.
        # @api private
        def self.empty_state
          {
            all_examples: {},
            duplicate_examples: Hash.new { |h, k| h[k] = [] },
            interrupted_examples: Set.new,
            flaky_examples: Set.new,
            failed_examples: Set.new,
            pending_examples: Set.new,
            skipped_examples: Set.new,
            all_files: {},
            dependency: Hash.new { |h, k| h[k] = Set.new },
            examples_coverage: {},
            boot_set: {},
            wsi_snapshot: {},
            env_snapshot: {},
            env_dependency: {},
            filtered_examples: {}
          }
        end

        # Union every field from one peer snapshot into the running
        # state. Each field has a distinct combine rule (merge-first-wins,
        # Set#merge, concat, or summing coverage strengths), so the
        # branching is inherent to the shape. Decomposing per-field would
        # scatter the merge contract.
        # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        def self.absorb(state, snapshot)
          state[:all_examples].merge!(snapshot.all_examples || {}) { |_, v, _| v }
          (snapshot.duplicate_examples || {}).each do |id, entries|
            state[:duplicate_examples][id].concat(entries)
          end
          state[:interrupted_examples].merge(snapshot.interrupted_examples || Set.new)
          state[:flaky_examples].merge(snapshot.flaky_examples || Set.new)
          state[:failed_examples].merge(snapshot.failed_examples || Set.new)
          state[:pending_examples].merge(snapshot.pending_examples || Set.new)
          state[:skipped_examples].merge(snapshot.skipped_examples || Set.new)
          state[:all_files].merge!(snapshot.all_files || {}) { |_, v, _| v }
          (snapshot.dependency || {}).each do |id, paths|
            state[:dependency][id].merge(paths)
          end
          merge_examples_coverage!(state[:examples_coverage], snapshot.examples_coverage || {})
          state[:boot_set].merge!(snapshot.boot_set || {})
          state[:wsi_snapshot].merge!(snapshot.wsi_snapshot || {})
          state[:env_snapshot].merge!(snapshot.env_snapshot || {})
          merge_env_dependency!(state[:env_dependency], snapshot.env_dependency || {})
          merge_filtered_examples!(state[:filtered_examples], snapshot.filtered_examples || {})
        end
        # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

        # Per-example env attribution unions set-wise: an example that
        # declared `tracks: { env: [A, B] }` on one worker and
        # `tracks: { env: [B, C] }` on another (edge case; parallel_tests
        # workers rarely run the same example) collapses to [A, B, C].
        def self.merge_env_dependency!(target, source)
          source.each do |id, names|
            existing = target[id] || []
            target[id] = (existing | Array(names)).sort
          end
        end

        # Merge per-worker filtered_examples by example_id. Every
        # parallel_tests worker independently runs Filter.select
        # against the same global previous-run snapshot
        # (Engine#compute_filter_decisions walks the registry seeded
        # from `prev` and the filter intersects against
        # `prev.all_examples.keys`), so every worker's filtered_examples
        # hash is IDENTICAL. First-write-wins collapses the duplicate
        # ids; `Merger.call` re-derives `cache_hit_reason` as the
        # values-tally of the merged hash so the merged
        # cache_hit_reason is the per-id-correct count (not the
        # N-fold-inflated sum of identical per-worker tallies that
        # the pre-#193 merge produced).
        def self.merge_filtered_examples!(target, source)
          source.each { |id, reason| target[id] ||= reason }
        end

        # Internal helper for the tracer pipeline.
        # @api private
        def self.merge_examples_coverage!(target, source)
          source.each do |id, per_file|
            entry = target[id] ||= {}
            per_file.each do |file_path, lines|
              file_entry = entry[file_path] ||= {}
              lines.each do |line_key, strength|
                file_entry[line_key] = (file_entry[line_key] || 0) + (strength || 0)
              end
            end
          end
        end

        # Internal helper for the tracer pipeline.
        # @api private
        def self.reverse_of(dependency)
          reverse = Hash.new { |h, k| h[k] = Set.new }
          dependency.each do |id, file_names|
            file_names.each { |name| reverse[name] << id }
          end
          reverse
        end
      end

      private

      # Internal method on the tracer pipeline.
      # @api private
      def last_run_path
        File.join(@cache_path, LAST_RUN_FILENAME)
      end

      # Internal method on the tracer pipeline.
      # @api private
      def lock_path
        File.join(@cache_path, LOCK_FILENAME)
      end

      # Internal method on the tracer pipeline.
      # @api private
      def maybe_prune_after_save
        prune_run_dirs!(keep: @retention_local_count) if @retention_local_count
      end

      # Internal constant.
      # @api private
      BYTES_PER_MB = 1_048_576
      private_constant :BYTES_PER_MB

      # Emit a warn-level log line for each just-saved file that
      # exceeded the per-file budget, and one total-budget line when
      # the whole cache tree exceeds that threshold. Both thresholds
      # are MiB; 0 / nil disables. The warning suggests the most
      # effective remediations in order: add_filter for vendor paths
      # (usually the biggest win), transitive_load_tracking off
      # (cuts the constants-blind-spot overhead), and the `:msgpack`
      # serializer (PR B). Budgets surface B11 symptoms (issue #15 /
      # #20) without forcing behavior change.
      def maybe_warn_size_budget(run_id)
        warn_oversized_run_files(run_id) if positive_threshold?(@warn_per_file_mb)
        warn_oversized_cache_total if positive_threshold?(@warn_total_mb)
      end

      # Internal method on the tracer pipeline.
      # @api private
      def positive_threshold?(value)
        value.is_a?(::Integer) && value.positive?
      end

      # Internal method on the tracer pipeline.
      # @api private
      def warn_oversized_run_files(run_id)
        run_dir = File.join(@cache_path, run_id)
        return unless File.directory?(run_dir)

        threshold_bytes = @warn_per_file_mb * BYTES_PER_MB
        per_file_glob(run_dir).each do |path|
          size = File.size(path)
          next unless size > threshold_bytes

          @logger&.warn(
            "rspec-tracer cache: #{File.basename(path)} is #{format_mib(size)} " \
            "(> #{@warn_per_file_mb} MiB per-file threshold); remediations (in order): " \
            'add_filter for vendor paths, `transitive_load_tracking false`, ' \
            '`storage_backend :json, serializer: :msgpack` for disk reduction'
          )
        end
      end

      # Internal method on the tracer pipeline.
      # @api private
      def warn_oversized_cache_total
        total = total_cache_size_bytes
        threshold_bytes = @warn_total_mb * BYTES_PER_MB
        return unless total > threshold_bytes

        @logger&.warn(
          "rspec-tracer cache: total size is #{format_mib(total)} " \
          "(> #{@warn_total_mb} MiB total threshold); remediations (in order): " \
          '`cache_retention_local_count N` to cap history, ' \
          'add_filter for vendor paths, ' \
          '`storage_backend :json, serializer: :msgpack` for disk reduction'
        )
      end

      # Glob matching this backend's serializer extension. Surfaces
      # the active on-disk layout so size-budget warnings stay
      # accurate when the user switches to `:msgpack` (.msgpack.gz
      # files instead of .json).
      def per_file_glob(run_dir)
        Dir[File.join(run_dir, "*.#{@serializer.extension}")]
      end

      # Internal method on the tracer pipeline.
      # @api private
      def total_cache_size_bytes
        total = 0
        Dir[File.join(@cache_path, '**', "*.#{@serializer.extension}")].each do |path|
          total += File.size(path) if File.file?(path)
        end
        total
      rescue StandardError
        0
      end

      # Internal method on the tracer pipeline.
      # @api private
      def format_mib(bytes)
        "#{(bytes.to_f / BYTES_PER_MB).round(1)} MiB"
      end

      # Enumerate run-id subdirectories of cache_path, newest first
      # by mtime. Non-directory children (last_run.json, lock file)
      # and dotfiles are excluded so a stray `.DS_Store` or editor
      # swap file doesn't confuse the prune math.
      def collect_run_dirs
        entries = Dir.children(@cache_path).filter_map do |name|
          next if name.start_with?('.')

          path = File.join(@cache_path, name)
          next unless File.directory?(path)

          [path, File.mtime(path).to_f]
        end
        entries.sort_by { |(_, mtime)| -mtime }.map(&:first)
      end

      # Split a newest-first list of run directories into (keep,
      # prune). The live `current` run-id is always retained even if
      # it fell off the top-N by mtime (defensive: an external
      # `touch` on an old dir must not force deletion of the live
      # one). Inputs are absolute paths; `current` is the basename
      # reported by `last_run_id` (may be nil if last_run.json is
      # missing or corrupt).
      def partition_dirs_to_prune(candidates, keep:, current:)
        keep_paths = []
        prune_paths = []
        candidates.each do |path|
          if keep_paths.size < keep || File.basename(path) == current
            keep_paths << path
          else
            prune_paths << path
          end
        end
        [keep_paths, prune_paths]
      end

      # Internal method on the tracer pipeline.
      # @api private
      def read_last_run_manifest
        return nil unless File.file?(last_run_path)

        read_json(last_run_path)
      rescue StandardError
        nil
      end

      # last_run.json is always plain JSON regardless of serializer -
      # it is the human-debuggable + CI-script-compatible pointer that
      # USER_FACING_SURFACE.md section 6 locks. Helper stays narrow so the
      # serializer dispatch can not accidentally reach it.
      def read_json(path)
        contents = File.read(path, encoding: ENCODING)
        JSON.parse(contents)
      end

      # Internal method on the tracer pipeline.
      # @api private
      def write_json_atomic(path, data)
        tmp_path = "#{path}.tmp.#{Process.pid}.#{rand(1_000_000)}"
        File.write(tmp_path, JSON.pretty_generate(data), encoding: ENCODING)
        File.rename(tmp_path, path)
      ensure
        File.delete(tmp_path) if tmp_path && File.file?(tmp_path)
      end

      # Internal method on the tracer pipeline.
      # @api private
      def write_run_files(dir, snapshot)
        HASH_FIELDS.each { |f| write_run_field(dir, f, snapshot.send(f) || {}) }
        ID_SET_FIELDS.each { |f| write_run_field(dir, f, serialize_id_set(snapshot.send(f))) }
        DEPENDENCY_FIELDS.each { |f| write_run_field(dir, f, serialize_dependency(snapshot.send(f))) }
      end

      # Internal method on the tracer pipeline.
      # @api private
      def write_run_field(dir, name, payload)
        write_payload_atomic(File.join(dir, field_filename(name.to_sym)), payload)
      end

      # Atomic write for a per-field payload. Encodes via the active
      # serializer; writes binary so msgpack + zlib bytes are not
      # re-encoded by Ruby's IO layer. Same tmp-rename pattern as
      # write_json_atomic (last_run.json commit point).
      def write_payload_atomic(path, data)
        tmp_path = "#{path}.tmp.#{Process.pid}.#{rand(1_000_000)}"
        File.binwrite(tmp_path, @serializer.encode(data))
        File.rename(tmp_path, path)
      ensure
        File.delete(tmp_path) if tmp_path && File.file?(tmp_path)
      end

      # Internal method on the tracer pipeline.
      # @api private
      def write_last_run_atomic(schema_version:, run_id:)
        manifest = { 'schema_version' => schema_version, 'run_id' => run_id, 'timestamp' => Time.now.utc.iso8601 }
        write_json_atomic(last_run_path, manifest)
      end

      # Dispatch one field's raw JSON body through the right
      # deserializer. Paired with FIELD_KINDS. Kept here rather
      # than on the reader so all shape knowledge stays in one
      # class; mutant sees one AST node per kind branch.
      def decode_field(field, raw)
        case FIELD_KINDS.fetch(field)
        when :symbolized    then deserialize_symbolized(raw)
        when :dupe_examples then deserialize_dupe_examples(raw)
        when :id_set        then deserialize_id_set(raw)
        when :dependency    then deserialize_dependency(raw)
        when :plain_hash    then deserialize_plain_hash(raw)
        end
      end

      # Plain-hash round-trip: JSON.parse returns nil on failure, and
      # a valid-but-wrong-shape file would otherwise poison the
      # Snapshot field. Treat anything non-Hash as the empty default.
      def deserialize_plain_hash(raw)
        raw.is_a?(Hash) ? raw : {}
      end

      # Walk a parsed JSON tree and replace every String with its
      # frozen-string-table entry via `String#-@`. Idempotent on
      # already-frozen Strings. Portable across every matrix Ruby
      # (json-gem's `freeze: true` option only arrived in 2.8 /
      # Ruby 3.4); the explicit walk keeps behavior identical on
      # Ruby 3.1 + 3.2 cells.
      #
      # Big win on dependency.json where the same file path repeats
      # across every example that depends on it - 2000 unique paths
      # may appear 1M+ times; interning collapses that to 2000
      # objects + refs. Small overhead on fields where strings are
      # unique (description text in all_examples) but the RAM
      # savings on the path-heavy fields dominate.
      def deep_intern(obj)
        case obj
        when Hash
          obj.each_with_object({}) { |(k, v), h| h[k.is_a?(String) ? -k : k] = deep_intern(v) }
        when Array
          obj.map { |v| deep_intern(v) }
        when String
          -obj
        else
          obj
        end
      end

      # Internal method on the tracer pipeline.
      # @api private
      def read_run_file(dir, name)
        path = File.join(dir, name)
        return nil unless File.file?(path)

        @serializer.decode(File.binread(path))
      rescue StandardError
        nil
      end

      # Sorted Array on disk, Set in memory - matches 1.x report_writer.
      def serialize_id_set(collection)
        return [] if collection.nil?

        collection.to_a.sort
      end

      # Internal method on the tracer pipeline.
      # @api private
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

      # Internal method on the tracer pipeline.
      # @api private
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

      # Internal method on the tracer pipeline.
      # @api private
      def info(message)
        @logger&.info(message)
      end

      # Map the user-facing `:json` / `:msgpack` name onto the
      # concrete Serializer class. A `:msgpack` request with the
      # msgpack gem absent warns once and falls back to `:json` so
      # the user's test suite keeps running (graceful-degradation
      # contract; same posture as the remote-cache optional deps).
      def resolve_serializer(name)
        case name
        when :json
          Serializer::Json
        when :msgpack
          Serializer::Msgpack.available? ? Serializer::Msgpack : msgpack_unavailable_fallback
        else
          raise ArgumentError,
                "unknown serializer: #{name.inspect}; allowed: [:json, :msgpack]"
        end
      end

      # Internal method on the tracer pipeline.
      # @api private
      def msgpack_unavailable_fallback
        @logger&.warn(
          'rspec-tracer cache: msgpack gem is not installed; falling back to :json. ' \
          "Add `gem 'msgpack'` to your Gemfile to use the :msgpack serializer."
        )
        Serializer::Json
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
