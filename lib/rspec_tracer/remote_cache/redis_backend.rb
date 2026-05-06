# frozen_string_literal: true

require 'fileutils'
require 'json'

require_relative 'archive'
require_relative 'backend'
require_relative 'validator'

module RSpecTracer
  # Internal RemoteCache — see {RSpecTracer} for the user-facing surface.
  # @api private
  module RemoteCache
    # Redis implementation of `RemoteCache::Backend`. Each cache ref is
    # one Redis hash keyed under the two-tier layout:
    #
    #   <prefix>:main:<sha>[:<test_suite_id>]           -> HASH
    #   <prefix>:pr:<branch>:<sha>[:<test_suite_id>]    -> HASH
    #   <prefix>:pr:<branch>:branch_refs                -> STRING (JSON)
    #
    # Hash fields per ref:
    #   _timestamp       -> epoch float (string; microsecond resolution
    #                        to keep within-second orderings stable for
    #                        count-based prune)
    #   last_run.json    -> JSON content verbatim
    #   <run_id>/<f>.json -> JSON content per file in the 15-file layout
    #
    # Why hashmap and not a binary archive (like S3 / LocalFs): hash-
    # per-ref is the idiomatic Redis data model, matches the brief, and
    # gives operational visibility via `redis-cli HGETALL` /
    # `HKEYS` / `HLEN` without extracting an archive first. The storage
    # cost (no gzip) is negligible for realistic cache sizes.
    #
    # Retention: identical dispatch to S3 / LocalFs. The orchestrator
    # calls `prune!(count:, duration_seconds:, pr_branch_ttl_seconds:)`
    # after each upload; this backend enumerates via SCAN + HGET on the
    # per-ref `_timestamp` field, then DELs stale keys. TTL-on-SET (i.e.
    # letting Redis EXPIRE handle it natively) is a reasonable ergonomic
    # followup but is not required for correctness - the explicit prune
    # pass already achieves the same eviction outcome.
    #
    # Graceful-degradation contract:
    #   - `redis` gem missing -> constructor raises RedisBackendError;
    #     UserTasks rescues at the top, logs a clear "add gem to your
    #     Gemfile" message, falls back to cold run. Never propagates.
    #   - Wire failure (connection refused, timeout) -> redis-rb raises
    #     Redis::BaseError subclasses. `download` catches and returns
    #     false; `upload` lets them propagate for the Rake task to log.
    #     Same rescue model as S3Backend.
    #
    # The `redis` gem is an OPTIONAL runtime dependency - users add
    # `gem 'redis'` to their own Gemfile to use RedisBackend. The
    # constructor calls `require 'redis'` lazily and raises a clear
    # RedisBackendError if the gem is absent, which UserTasks converts
    # into a warning + cold run.
    class RedisBackend
      # Internal RedisBackendError — see {RSpecTracer} for the user-facing surface.
      # @api private
      class RedisBackendError < StandardError; end

      # Internal constant.
      # @api private
      MAIN_TIER = 'main'
      # Internal constant.
      # @api private
      PR_TIER = 'pr'
      # Internal constant.
      # @api private
      BRANCH_REFS_SUFFIX = 'branch_refs'
      # Internal constant.
      # @api private
      PR_BRANCHES_SUFFIX = 'pr_branches'
      # Internal constant.
      # @api private
      LAST_RUN_FIELD = 'last_run.json'
      # Internal constant.
      # @api private
      TIMESTAMP_FIELD = '_timestamp'
      # Internal constant.
      # @api private
      ENCODING = 'UTF-8'
      # Internal constant.
      # @api private
      DEFAULT_SCAN_COUNT = 200

      # rubocop:disable Metrics/ParameterLists
      def initialize(prefix:, branch:, default_branch:, cache_path:,
                     url: nil, redis_client: nil, test_suite_id: nil, logger: nil,
                     ttl: nil)
        validate_required!(prefix: prefix, branch: branch,
                           default_branch: default_branch, cache_path: cache_path)
        validate_connection_source!(url: url, redis_client: redis_client)
        validate_ttl!(ttl)

        @prefix = trim_trailing_colons(prefix.to_s)
        @branch = branch.to_s.chomp
        @default_branch = default_branch.to_s.chomp
        @test_suite_id = normalize_test_suite_id(test_suite_id)
        @cache_path = cache_path.to_s
        @logger = logger
        @ttl = ttl
        @redis = redis_client || build_client(url)
      end
      # rubocop:enable Metrics/ParameterLists

      # Download cache for `ref`. Tries own tier, falls back to main
      # tier. Returns true on validated success, false otherwise.
      # Cleans up partially-written files on failure.
      #
      # `tree_sha:` is accepted for protocol uniformity with S3Backend
      # but is currently a no-op: the tree-SHA secondary index is an
      # S3-only feature. Future enhancement may extend it here; the
      # orchestrator already forwards the kwarg.
      def download(ref, tree_sha: nil)
        _ = tree_sha
        return false if blank?(ref)

        tiers_to_try = [own_tier_segment]
        tiers_to_try << MAIN_TIER if pr_tier?

        tiers_to_try.any? { |tier| try_download_from(tier, ref) }
      end

      # Upload local cache as a hash under own-tier key. Raises on I/O
      # or Redis wire failure.
      #
      # `tree_sha:` is accepted for protocol uniformity with S3Backend
      # (no-op here; see `download`).
      def upload(ref, tree_sha: nil)
        _ = tree_sha
        raise RedisBackendError, 'ref is required' if blank?(ref)

        run_id = read_local_run_id
        raise RedisBackendError, "no local cache to upload (missing #{LAST_RUN_FIELD})" if run_id.nil?

        fields = build_upload_fields(run_id)
        key = ref_key(own_tier_segment, ref)
        write_upload_hash(key, fields)
        log_debug("uploaded cache for #{ref} to #{own_tier_segment} (#{fields.size} fields)")
      end

      # Read branch_refs for the given branch. Returns
      # `{sha => ts_epoch}` or `{}` when missing / malformed.
      def branch_refs(branch_name)
        return {} if blank?(branch_name)

        raw = @redis.get(branch_refs_key(branch_name))
        return {} if raw.nil? || raw.empty?

        parsed = JSON.parse(raw)
        parsed.is_a?(Hash) ? parsed.transform_values(&:to_i) : {}
      rescue StandardError => e
        log_debug("branch_refs read failed (#{e.class}: #{e.message}); treating as empty")
        {}
      end

      # Persist branch_refs for the given branch. No-op for main-branch
      # writes. Raises on Redis wire failure for PR tier.
      def write_branch_refs(branch_name, refs)
        return if blank?(branch_name)
        return if branch_name.to_s.chomp == @default_branch
        return if refs.nil? || refs.empty?

        @redis.set(branch_refs_key(branch_name), JSON.pretty_generate(refs))
        log_debug("wrote branch_refs for #{branch_name}")
      end

      # Apply retention to own tier. Returns count removed. Two or more
      # knobs may be set; each applies independently. Never raises - a
      # wire-level Redis error on any sub-prune logs + is absorbed.
      # rubocop:disable Metrics/PerceivedComplexity
      def prune!(count: nil, duration_seconds: nil, pr_branch_ttl_seconds: nil)
        removed = 0
        removed += prune_by_count!(count) if count&.positive?
        removed += prune_by_duration!(duration_seconds) if duration_seconds&.positive?
        removed += prune_dead_pr_branch!(pr_branch_ttl_seconds) if pr_tier? && pr_branch_ttl_seconds&.positive?
        removed
      rescue StandardError => e
        log_warn("prune! failed (#{e.class}: #{e.message}); returning #{removed}")
        removed
      end
      # rubocop:enable Metrics/PerceivedComplexity

      # Cross-tier PR-branch cleanup. Enumerates every PR branch under
      # the configured prefix (by scanning for `<prefix>:pr:<branch>:branch_refs`
      # keys and deriving branch names), applies the TTL to each,
      # deletes dead branches whole. Returns total refs removed. No-op
      # on nil / non-positive TTL.
      def prune_all!(pr_branch_ttl_seconds: nil)
        return 0 unless pr_branch_ttl_seconds&.positive?

        cutoff = Time.now.to_i - pr_branch_ttl_seconds.to_i
        branches = discover_pr_branches
        branches.sum { |branch| maybe_prune_branch(branch, cutoff) }
      rescue StandardError => e
        log_warn("prune_all! failed (#{e.class}: #{e.message})")
        0
      end

      # Warn when main tier has grown beyond threshold and no retention
      # is configured.
      def unbounded_warning(warn_threshold: 500)
        count = count_tier_refs(MAIN_TIER)
        return nil unless count > warn_threshold

        "rspec-tracer remote cache has #{count} refs in #{@prefix}:#{MAIN_TIER}; " \
          'configure cache_retention_count or cache_retention_duration to cap growth'
      end

      private

      # Internal method on the tracer pipeline.
      # @api private
      def blank?(value)
        value.nil? || value.to_s.empty?
      end

      # Internal method on the tracer pipeline.
      # @api private
      def validate_required!(**opts)
        opts.each do |key, value|
          raise RedisBackendError, "#{key} is required" if blank?(value)
        end
      end

      # Internal method on the tracer pipeline.
      # @api private
      def validate_connection_source!(url:, redis_client:)
        return if redis_client
        raise RedisBackendError, 'url or redis_client is required' if blank?(url)
      end

      # Optional kwarg. nil disables TTL (per-key persistence determined
      # by the user's Redis eviction policy). Positive integer enables
      # `EXPIRE <key> <ttl>` inside the upload's MULTI block, atomic
      # with the SET. Mirrors `cache_retention_count`-style validation.
      def validate_ttl!(ttl)
        return if ttl.nil?
        return if ttl.is_a?(::Integer) && ttl.positive?

        raise RedisBackendError,
              "ttl must be a positive integer (seconds) or nil, got #{ttl.inspect}"
      end

      # Internal method on the tracer pipeline.
      # @api private
      def build_client(url)
        require 'redis'
        ::Redis.new(url: url)
      rescue LoadError
        raise RedisBackendError,
              "redis gem is not installed; add `gem 'redis'` to your Gemfile to use RedisBackend"
      end

      # Internal method on the tracer pipeline.
      # @api private
      def normalize_test_suite_id(raw)
        return nil if raw.nil?

        value = raw.to_s
        value.empty? ? nil : value
      end

      # Internal method on the tracer pipeline.
      # @api private
      def trim_trailing_colons(str)
        value = str.dup
        value.chop! while value.end_with?(':')
        value
      end

      # Internal method on the tracer pipeline.
      # @api private
      def pr_tier?
        @branch != @default_branch
      end

      # Internal method on the tracer pipeline.
      # @api private
      def own_tier_segment
        pr_tier? ? "#{PR_TIER}:#{@branch}" : MAIN_TIER
      end

      # Internal method on the tracer pipeline.
      # @api private
      def ref_key(tier_segment, ref)
        [@prefix, tier_segment, ref, @test_suite_id].compact.reject(&:empty?).join(':')
      end

      # Internal method on the tracer pipeline.
      # @api private
      def branch_refs_key(branch_name)
        [@prefix, PR_TIER, branch_name.chomp, BRANCH_REFS_SUFFIX].join(':')
      end

      # Internal method on the tracer pipeline.
      # @api private
      def local_last_run_path
        File.join(@cache_path, LAST_RUN_FIELD)
      end

      # Internal method on the tracer pipeline.
      # @api private
      def local_run_dir(run_id)
        File.join(@cache_path, run_id)
      end

      # Internal method on the tracer pipeline.
      # @api private
      def read_local_run_id
        return nil unless File.file?(local_last_run_path)

        manifest = JSON.parse(File.read(local_last_run_path, encoding: ENCODING))
        return nil unless manifest.is_a?(Hash)

        run_id = manifest['run_id']
        return nil if blank?(run_id)

        run_id
      rescue StandardError
        nil
      end

      # Internal method on the tracer pipeline.
      # @api private
      def build_upload_fields(run_id)
        # Float seconds, not integer - multiple uploads within the
        # same clock second otherwise collide on _timestamp and make
        # count-based prune pick arbitrary survivors. Float keeps
        # microsecond ordering stable under realistic CI cadences.
        fields = { TIMESTAMP_FIELD => Time.now.to_f.to_s }
        fields[LAST_RUN_FIELD] = File.read(local_last_run_path, encoding: ENCODING)
        Dir[File.join(local_run_dir(run_id), '*.json')].each do |path|
          fields["#{run_id}/#{File.basename(path)}"] = File.read(path, encoding: ENCODING)
        end
        fields
      end

      # Upload MULTI: DEL + HSET + optional EXPIRE + optional sidecar
      # SADD, all atomic under one round-trip.
      #
      # DEL flushes any stale fields from a prior upload under the same
      # ref before HSET installs the new field set (prevents partial
      # overlay when a retried upload has a subset of keys the first
      # attempt had). EXPIRE fires only when @ttl is set (per-key TTL
      # atomic with the SET; nil means no TTL, user controls eviction
      # via Redis policy + the explicit prune pass). SADD into the
      # PR-branches sidecar fires only on PR-tier uploads (main-tier
      # uploads skip; sidecar is operational telemetry for ops
      # dashboards via SMEMBERS).
      def write_upload_hash(key, fields)
        @redis.multi do |tx|
          tx.del(key)
          tx.hset(key, fields)
          tx.expire(key, @ttl) if @ttl
          tx.sadd(pr_branches_key, @branch) if pr_tier?
        end
      end

      # Sidecar key tracking which PR branches have ever uploaded to
      # this prefix. Operational telemetry for ops dashboards
      # (`SMEMBERS <prefix>:pr_branches`); does not affect download
      # semantics. Unconditionally namespaced under the configured
      # prefix; PR-tier uploads SADD into it, main-tier uploads
      # skip it.
      def pr_branches_key
        "#{@prefix}:#{PR_BRANCHES_SUFFIX}"
      end

      # Internal method on the tracer pipeline.
      # @api private
      def try_download_from(tier_segment, ref)
        key = ref_key(tier_segment, ref)
        fields = @redis.hgetall(key)
        return false if fields.nil? || fields.empty?

        extract_and_validate(fields, tier_segment, ref)
      rescue StandardError => e
        log_debug("download failed for #{tier_segment}/#{ref}: #{e.class}: #{e.message}")
        rollback_extracted_cache
        false
      end

      # Action-style method (writes files + cleans up on failure), not a
      # pure predicate. The bool return is the "did we land a valid
      # cache" signal; renaming to `?` would misread the method as a
      # query that happens to perform I/O.
      # rubocop:disable Naming/PredicateMethod
      def extract_and_validate(fields, tier_segment, ref)
        write_fields_to_disk(fields)

        return true if Validator.valid_file?(local_last_run_path)

        log_debug("rejected #{tier_segment}/#{ref}: schema_version mismatch")
        rollback_extracted_cache
        false
      end
      # rubocop:enable Naming/PredicateMethod

      def write_fields_to_disk(fields)
        FileUtils.mkdir_p(@cache_path)
        fields.each do |field, content|
          next if field == TIMESTAMP_FIELD

          safe_name = Archive.safe_entry_name(field)
          next if safe_name.nil?

          dest = File.join(@cache_path, safe_name)
          FileUtils.mkdir_p(File.dirname(dest))
          File.write(dest, content, encoding: ENCODING)
        end
      end

      # Internal method on the tracer pipeline.
      # @api private
      def rollback_extracted_cache
        run_id = read_local_run_id
        FileUtils.rm_f(local_last_run_path)
        FileUtils.rm_rf(local_run_dir(run_id)) if run_id
      end

      # List refs in `tier_segment` as Array<[key, ts_epoch]>,
      # newest-first. Returns full Redis keys (not just the ref sha)
      # because prune_by_* deletes those keys directly.
      def list_refs_in_tier(tier_segment)
        pattern = "#{@prefix}:#{tier_segment}:*"
        keys = scan_matching_keys(pattern).reject { |k| branch_refs_key?(k) }
        return [] if keys.empty?

        entries = keys.map { |k| [k, fetch_timestamp(k)] }.reject { |(_, ts)| ts.nil? }
        entries.sort_by { |(_, ts)| -ts }
      end

      # Internal method on the tracer pipeline.
      # @api private
      def scan_matching_keys(pattern)
        @redis.scan_each(match: pattern, count: DEFAULT_SCAN_COUNT).to_a
      end

      # Internal method on the tracer pipeline.
      # @api private
      def branch_refs_key?(key)
        key.end_with?(":#{BRANCH_REFS_SUFFIX}")
      end

      # Internal method on the tracer pipeline.
      # @api private
      def fetch_timestamp(key)
        raw = @redis.hget(key, TIMESTAMP_FIELD)
        return nil if raw.nil?

        raw.to_f
      end

      # Internal method on the tracer pipeline.
      # @api private
      def count_tier_refs(tier_segment)
        pattern = "#{@prefix}:#{tier_segment}:*"
        scan_matching_keys(pattern).count { |k| !branch_refs_key?(k) }
      end

      # Internal method on the tracer pipeline.
      # @api private
      def prune_by_count!(count)
        entries = list_refs_in_tier(own_tier_segment)
        return 0 if entries.length <= count

        to_delete = entries[count..] || []
        delete_keys(to_delete.map(&:first))
      end

      # Internal method on the tracer pipeline.
      # @api private
      def prune_by_duration!(duration_seconds)
        cutoff = Time.now.to_i - duration_seconds.to_i
        stale_keys = list_refs_in_tier(own_tier_segment)
          .select { |(_, ts)| ts < cutoff }
          .map(&:first)
        delete_keys(stale_keys)
      end

      # Internal method on the tracer pipeline.
      # @api private
      def delete_keys(keys)
        return 0 if keys.empty?

        @redis.del(*keys)
        keys.each { |k| log_debug("pruned key #{k}") }
        keys.length
      end

      # Internal method on the tracer pipeline.
      # @api private
      def prune_dead_pr_branch!(ttl_seconds)
        entries = list_refs_in_tier(own_tier_segment)
        return 0 if entries.empty?

        newest_ts = entries.first[1]
        return 0 if newest_ts >= Time.now.to_i - ttl_seconds.to_i

        delete_branch_prefix(@branch, entries.length)
      end

      # Delete every cache key + branch_refs under a given PR branch.
      # Returns the supplied `ref_count` on success, 0 on failure.
      def delete_branch_prefix(branch_name, ref_count)
        pattern = "#{@prefix}:#{PR_TIER}:#{branch_name}:*"
        keys = scan_matching_keys(pattern)
        @redis.del(*keys) unless keys.empty?
        log_debug("pruned dead PR branch #{PR_TIER}:#{branch_name} (#{keys.length} keys)")
        ref_count
      rescue StandardError => e
        log_warn("failed to prune dead PR branch #{PR_TIER}:#{branch_name}: #{e.class}: #{e.message}")
        0
      end

      # Internal method on the tracer pipeline.
      # @api private
      def discover_pr_branches
        pattern = "#{@prefix}:#{PR_TIER}:*:#{BRANCH_REFS_SUFFIX}"
        prefix_head = "#{@prefix}:#{PR_TIER}:"
        scan_matching_keys(pattern).map do |key|
          remainder = key[prefix_head.length..]
          remainder.delete_suffix(":#{BRANCH_REFS_SUFFIX}")
        end
      end

      # Internal method on the tracer pipeline.
      # @api private
      def maybe_prune_branch(branch_name, cutoff)
        tier_segment = "#{PR_TIER}:#{branch_name}"
        entries = list_refs_in_tier(tier_segment)
        return 0 if entries.empty?

        newest_ts = entries.first[1]
        return 0 if newest_ts >= cutoff

        delete_branch_prefix(branch_name, entries.length)
      end

      # Internal method on the tracer pipeline.
      # @api private
      def log_debug(message)
        @logger&.debug("rspec-tracer remote_cache: #{message}")
      end

      # Internal method on the tracer pipeline.
      # @api private
      def log_warn(message)
        @logger&.warn("rspec-tracer remote_cache: #{message}")
      end
    end
  end
end
