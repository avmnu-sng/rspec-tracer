# frozen_string_literal: true

require 'json'
require 'open3'
require 'securerandom'
require 'set'
require 'time'
require 'tmpdir'

require_relative 'archive'
require_relative 'backend'
require_relative 'validator'

module RSpecTracer
  module RemoteCache
    # S3 implementation of `RemoteCache::Backend`. Shells out to the
    # `aws` / `awslocal` CLI for every operation - matches 1.x's
    # behavior and avoids pulling `aws-sdk-s3` into the gem's runtime
    # deps. Users on 1.x already have `aws` on PATH per the documented
    # CI recipe; 2.0 asks nothing new.
    #
    # Two-tier S3 layout (change from 1.x flat layout; paired with the
    # schema_version bump - one cold run on upgrade). Cache payload is
    # a single `cache.tar.gz` per ref (~15 JSON files + last_run.json
    # packed together; ~4-6x smaller on the wire + 1 GET per download
    # instead of 15):
    #
    #   s3://<bucket>/<prefix>/
    #     main/<sha>/[<test_suite_id>/]cache.tar.gz
    #     pr/<branch>/<sha>/[<test_suite_id>/]cache.tar.gz
    #     pr/<branch>/branch_refs.json
    #
    # Local cache_path layout is unchanged - the archive is a transit
    # boundary only. Users and external tooling continue to see the
    # 15-file disk layout documented in `USER_FACING_SURFACE.md` §6.
    #
    # Tier is determined from `branch` vs `default_branch` at construction.
    # Main-branch builds write to main tier; PR builds write to their
    # branch-scoped pr tier. Download tries the backend's own tier first,
    # then falls back to main tier for the same ref (catches PRs
    # cherry-picking from main).
    #
    # Retention (closes issue #20 at the architectural layer, not just
    # with a knob):
    #   - `cache_retention_count N` keeps newest N refs per tier
    #     (main has N refs, each PR branch has N refs).
    #   - `cache_retention_duration_seconds X` prunes refs older than
    #     X seconds in any tier the backend visits.
    #   - `cache_retention_pr_branch_ttl_seconds X` deletes a PR branch
    #     entirely (including its branch_refs.json) when no ref has
    #     been touched in X seconds. Applied at upload time in the
    #     backend's own branch only; cross-branch cleanup is a separate
    #     Rake task (deferred to M7.2).
    #
    # Graceful-degradation contract:
    #   - `download` returns false and never raises on wire/validation
    #     failure. Partial downloads are cleaned up.
    #   - `upload` raises on wire failure; the Rake task catches.
    #   - `branch_refs` returns `{}` on missing file.
    #   - `prune!` returns count removed, never raises.
    #
    # S3 shells out via `aws` CLI - a single class is the natural unit
    # of composition here. M8.3 mutation-smoke addition may push this
    # over the limit further; splitting would be cosmetic.
    # rubocop:disable Metrics/ClassLength
    class S3Backend
      class S3BackendError < StandardError; end

      MAIN_TIER = 'main'
      PR_TIER = 'pr'
      BRANCH_REFS_FILENAME = 'branch_refs.json'
      LAST_RUN_FILENAME = 'last_run.json'
      CACHE_ARCHIVE_FILENAME = Archive::CACHE_FILENAME
      ENCODING = 'UTF-8'

      REQUIRED_OPTS = %i[bucket prefix branch default_branch cache_path].freeze

      # rubocop:disable Metrics/ParameterLists
      def initialize(bucket:, prefix:, branch:, default_branch:,
                     cache_path:, test_suite_id: nil, local: false, logger: nil)
        validate_required!(bucket: bucket, prefix: prefix, branch: branch,
                           default_branch: default_branch, cache_path: cache_path)

        @bucket = bucket.to_s
        @prefix = trim_trailing_slashes(prefix.to_s)
        @branch = branch.to_s.chomp
        @default_branch = default_branch.to_s.chomp
        @test_suite_id = normalize_test_suite_id(test_suite_id)
        @cache_path = cache_path.to_s
        @cli_binary = local ? 'awslocal' : 'aws'
        @logger = logger
      end
      # rubocop:enable Metrics/ParameterLists

      # Download the cache for `ref` into `cache_path`. Tries the
      # backend's own tier first; on miss, falls back to the main tier
      # for the same ref. Validates the downloaded `last_run.json` via
      # schema_version before declaring success.
      #
      # Returns true on validated success, false on any failure. Cleans
      # up partially-downloaded files on failure so a subsequent fresh
      # load doesn't see stale data.
      def download(ref)
        return false if ref.nil? || ref.to_s.empty?

        tiers_to_try = [own_tier_prefix]
        tiers_to_try << main_tier_prefix if pr_tier?

        tiers_to_try.any? { |tier| try_download_from(tier, ref) }
      end

      # Upload the local cache to this backend's own tier under `ref`.
      # Packs the 15-file local layout into a single `cache.tar.gz` and
      # uploads that one object. Raises on wire failure. Idempotent.
      def upload(ref)
        raise S3BackendError, 'ref is required' if blank?(ref)

        run_id = read_local_run_id
        raise S3BackendError, "no local cache to upload (missing #{LAST_RUN_FILENAME})" if run_id.nil?

        archive_path = tmp_archive_path('upload')
        begin
          Archive.pack(cache_path: @cache_path, run_id: run_id, dest_path: archive_path)
          upload_file(archive_path, s3_archive_key(own_tier_prefix, ref))
          log_debug("uploaded cache for #{ref} to #{own_tier_prefix} (#{File.size(archive_path)} bytes)")
        ensure
          FileUtils.rm_f(archive_path)
        end
      end

      # Read branch_refs for the given branch. Returns `{sha => ts_epoch}`
      # or `{}` when the file is missing / malformed. PR tier only -
      # main branch doesn't track branch_refs (rewrites not expected on
      # the default branch).
      def branch_refs(branch_name)
        return {} if blank?(branch_name)

        local_tmp = File.join(@cache_path, ".branch_refs_download_#{Process.pid}.json")
        FileUtils.mkdir_p(@cache_path)

        ok, = aws_cp_silent(s3_url(s3_branch_refs_key(branch_name)), local_tmp)
        return {} unless ok

        parsed = JSON.parse(File.read(local_tmp, encoding: ENCODING))
        parsed.is_a?(Hash) ? parsed.transform_values(&:to_i) : {}
      rescue StandardError => e
        log_debug("branch_refs read failed (#{e.class}: #{e.message}); treating as empty")
        {}
      ensure
        FileUtils.rm_f(local_tmp) if defined?(local_tmp) && local_tmp
      end

      # Persist branch_refs for the given branch. No-op for main-branch
      # writes (main-branch doesn't use branch_refs). Raises on wire
      # failure for PR tier.
      def write_branch_refs(branch_name, refs)
        return if blank?(branch_name)
        return if branch_name.to_s.chomp == @default_branch
        return if refs.nil? || refs.empty?

        FileUtils.mkdir_p(@cache_path)
        local_tmp = File.join(@cache_path, ".branch_refs_upload_#{Process.pid}.json")
        File.write(local_tmp, JSON.pretty_generate(refs), encoding: ENCODING)

        ok, _stdout, stderr = aws_cp_silent(local_tmp, s3_url(s3_branch_refs_key(branch_name)))
        raise S3BackendError, "Failed to upload branch_refs for #{branch_name}: #{stderr.chomp}" unless ok

        log_debug("wrote branch_refs for #{branch_name}")
      ensure
        FileUtils.rm_f(local_tmp) if defined?(local_tmp) && local_tmp
      end

      # Apply retention policy to the backend's own tier. Returns the
      # number of refs removed. Never raises on a partial failure; logs
      # and returns the count it managed to delete.
      #
      # Semantics:
      #   - count N: keep newest N refs, delete older.
      #   - duration_seconds X: delete refs whose last_run.json is
      #     older than X seconds.
      #   - pr_branch_ttl_seconds X: (PR tier only) if the backend's
      #     branch has no ref newer than X seconds, delete the entire
      #     pr/<branch>/ prefix (branch_refs.json included).
      #
      # Two or more parameters may be set; each applies independently.
      # All nil/0 => no-op.
      def prune!(count: nil, duration_seconds: nil, pr_branch_ttl_seconds: nil)
        removed = 0
        removed += prune_by_count!(count) if count&.positive?
        removed += prune_by_duration!(duration_seconds) if duration_seconds&.positive?
        removed += prune_dead_pr_branch!(pr_branch_ttl_seconds) if pr_tier? && pr_branch_ttl_seconds&.positive?
        removed
      end

      # Cross-tier PR-branch cleanup. Enumerates every PR branch under
      # the configured prefix by listing the `pr/` subtree, applies the
      # TTL to each branch, deletes dead branches whole. Returns total
      # refs removed. No-op on nil / non-positive TTL. Never raises
      # (graceful-degradation contract).
      def prune_all!(pr_branch_ttl_seconds: nil)
        return 0 unless pr_branch_ttl_seconds&.positive?

        cutoff = Time.now.to_i - pr_branch_ttl_seconds.to_i
        branches = discover_pr_branches
        branches.sum { |branch| maybe_prune_branch(branch, cutoff) }
      rescue StandardError => e
        log_warn("prune_all! failed (#{e.class}: #{e.message})")
        0
      end

      # Check whether the backend's own tier has accumulated more than
      # `warn_threshold` refs without retention configured. Callable
      # from orchestrator for the "S3 growing unbounded" diagnostic.
      def unbounded_warning(warn_threshold: 500)
        refs = list_own_tier_refs
        return nil unless refs.length > warn_threshold

        "rspec-tracer remote cache has #{refs.length} refs in #{own_tier_prefix}; " \
          'configure cache_retention_count or cache_retention_duration to cap growth'
      end

      private

      def blank?(value)
        value.nil? || value.to_s.empty?
      end

      # Non-regex trailing-slash strip. The literal `/+\z` pattern trips
      # CodeQL's `rb/polynomial-redos` heuristic because quantifier-on-
      # library-input is a conservative-fail signal; the pattern is
      # backtracking-safe in practice, but String#chop in a loop is
      # both obviously safe and faster on short inputs.
      def trim_trailing_slashes(str)
        value = str.dup
        value.chop! while value.end_with?('/')
        value
      end

      def validate_required!(**opts)
        opts.each do |key, value|
          raise S3BackendError, "#{key} is required" if blank?(value)
        end
      end

      def normalize_test_suite_id(raw)
        return nil if raw.nil?

        value = raw.to_s
        value.empty? ? nil : value
      end

      # ── Tier + key composition ─────────────────────────

      def pr_tier?
        @branch != @default_branch
      end

      def own_tier_prefix
        pr_tier? ? "#{PR_TIER}/#{@branch}" : MAIN_TIER
      end

      def main_tier_prefix
        MAIN_TIER
      end

      def s3_url(key)
        "s3://#{@bucket}/#{key}"
      end

      def s3_archive_key(tier_prefix, ref)
        join_key(@prefix, tier_prefix, ref, @test_suite_id, CACHE_ARCHIVE_FILENAME)
      end

      def s3_branch_refs_key(branch_name)
        join_key(@prefix, PR_TIER, branch_name.chomp, BRANCH_REFS_FILENAME)
      end

      def s3_ref_prefix_url(tier_prefix, ref)
        "#{s3_url(join_key(@prefix, tier_prefix, ref))}/"
      end

      def s3_tier_prefix_url(tier_prefix)
        "#{s3_url(join_key(@prefix, tier_prefix))}/"
      end

      def join_key(*segments)
        segments.compact.reject { |s| s.to_s.empty? }.join('/')
      end

      # ── Local-side paths ───────────────────────────────

      def local_last_run_path
        File.join(@cache_path, LAST_RUN_FILENAME)
      end

      def local_run_dir(run_id)
        File.join(@cache_path, run_id)
      end

      def read_local_run_id
        return nil unless File.file?(local_last_run_path)

        manifest = JSON.parse(File.read(local_last_run_path, encoding: ENCODING))
        return nil unless manifest.is_a?(Hash)

        run_id = manifest['run_id']
        return nil if run_id.nil? || run_id.to_s.empty?

        run_id
      rescue StandardError
        nil
      end

      # ── Download flow ──────────────────────────────────

      # Download the archive for (tier, ref), extract into cache_path,
      # validate the resulting last_run.json. Returns true on validated
      # success, false otherwise; rolls back extracted files on failure
      # so a later reader never sees a half-landed cache. Action-style
      # method (writes files + cleans up), not a predicate.
      # rubocop:disable Naming/PredicateMethod
      def try_download_from(tier_prefix, ref)
        archive_path = tmp_archive_path('download')
        ok, = aws_cp_silent(s3_url(s3_archive_key(tier_prefix, ref)), archive_path)
        return false unless ok

        extract_and_validate(archive_path, tier_prefix, ref)
      ensure
        FileUtils.rm_f(archive_path) if defined?(archive_path) && archive_path
      end

      def extract_and_validate(archive_path, tier_prefix, ref)
        begin
          Archive.extract(archive_path: archive_path, dest_dir: @cache_path)
        rescue StandardError => e
          log_debug("extract failed for #{tier_prefix}/#{ref}: #{e.class}: #{e.message}")
          rollback_extracted_cache
          return false
        end

        return true if Validator.valid_file?(local_last_run_path)

        log_debug("rejected #{tier_prefix}/#{ref}: schema_version mismatch")
        rollback_extracted_cache
        false
      end
      # rubocop:enable Naming/PredicateMethod

      def rollback_extracted_cache
        run_id = read_local_run_id
        FileUtils.rm_f(local_last_run_path)
        FileUtils.rm_rf(local_run_dir(run_id)) if run_id
      end

      def tmp_archive_path(purpose)
        FileUtils.mkdir_p(@cache_path)
        File.join(@cache_path, ".cache_#{purpose}_#{Process.pid}_#{SecureRandom.hex(4)}.tar.gz")
      end

      # ── Upload flow ────────────────────────────────────

      def upload_file(local_path, s3_key)
        ok, _stdout, stderr = aws_cp_silent(local_path, s3_url(s3_key))
        raise S3BackendError, "Failed to upload #{local_path}: #{stderr.chomp}" unless ok
      end

      # ── Retention ──────────────────────────────────────

      # List refs under the backend's own tier with their last_run.json
      # LastModified. Returns Array<[ref, epoch_timestamp]>, newest first.
      def list_own_tier_refs
        list_refs_in_tier(own_tier_prefix)
      end

      def list_refs_in_tier(tier_prefix)
        entries = list_objects(join_key(@prefix, tier_prefix))
        return [] if entries.empty?

        refs = {}
        entries.each do |entry|
          key = entry['Key']
          next unless key.end_with?("/#{CACHE_ARCHIVE_FILENAME}")

          ref = extract_ref_from_archive_key(key, tier_prefix)
          next if ref.nil?

          ts = parse_s3_timestamp(entry['LastModified'])
          existing = refs[ref]
          refs[ref] = ts if existing.nil? || ts > existing
        end
        refs.sort_by { |_, ts| -ts }
      end

      # Keys look like: <prefix>/<tier_prefix>/<ref>/[<test_suite_id>/]cache.tar.gz
      # We want <ref>.
      def extract_ref_from_archive_key(key, tier_prefix)
        tier_head = "#{join_key(@prefix, tier_prefix)}/"
        return nil unless key.start_with?(tier_head)

        remainder = key[tier_head.length..]
        segments = remainder.split('/')
        return nil if segments.length < 2

        segments.first
      end

      def prune_by_count!(count)
        refs = list_own_tier_refs
        return 0 if refs.length <= count

        to_delete = refs[count..] || []
        delete_refs(to_delete.map(&:first))
      end

      def prune_by_duration!(duration_seconds)
        cutoff = Time.now.to_i - duration_seconds.to_i
        stale = list_own_tier_refs.select { |_, ts| ts < cutoff }.map(&:first)
        delete_refs(stale)
      end

      def delete_refs(refs)
        removed = 0
        refs.each do |ref|
          ok, _stdout, stderr = aws_rm_recursive_silent(s3_ref_prefix_url(own_tier_prefix, ref))
          if ok
            removed += 1
            log_debug("pruned ref #{own_tier_prefix}/#{ref}")
          else
            log_warn("failed to prune ref #{own_tier_prefix}/#{ref}: #{stderr.chomp}")
          end
        end
        removed
      end

      def prune_dead_pr_branch!(ttl_seconds)
        refs = list_own_tier_refs
        return 0 if refs.empty?

        newest_ts = refs.first[1]
        return 0 if newest_ts >= Time.now.to_i - ttl_seconds.to_i

        delete_branch_prefix(own_tier_prefix, refs.length)
      end

      # Delete every object under `<prefix>/<tier_prefix>/` (cache refs
      # + branch_refs.json). Returns the supplied `ref_count` on
      # success, 0 on failure.
      def delete_branch_prefix(tier_prefix, ref_count)
        ok, _stdout, stderr = aws_rm_recursive_silent(s3_tier_prefix_url(tier_prefix))
        if ok
          log_debug("pruned dead PR branch #{tier_prefix} (#{ref_count} refs)")
          ref_count
        else
          log_warn("failed to prune dead PR branch #{tier_prefix}: #{stderr.chomp}")
          0
        end
      end

      # Enumerate PR branches under the configured prefix. Returns an
      # Array<String> of branch names (one per unique `pr/<branch>/`
      # segment). Uses `list-objects-v2 --prefix pr/ --delimiter /` so
      # we pay for one bucket listing instead of walking every object.
      def discover_pr_branches
        prefix_head = "#{join_key(@prefix, PR_TIER)}/"
        common_prefixes = list_common_prefixes(prefix_head)
        return [] if common_prefixes.empty?

        branches = Set.new
        common_prefixes.each do |entry|
          value = entry['Prefix']
          next if value.nil? || !value.start_with?(prefix_head)

          branch = value[prefix_head.length..].delete_suffix('/')
          branches << branch unless branch.empty?
        end
        branches.to_a
      end

      def list_common_prefixes(prefix)
        stdout, stderr, status = Open3.capture3(
          @cli_binary, 's3api', 'list-objects-v2',
          '--bucket', @bucket,
          '--prefix', prefix,
          '--delimiter', '/',
          '--output', 'json'
        )
        unless status.success?
          log_debug("list-objects-v2 (delimited) #{prefix} failed: #{stderr.chomp}")
          return []
        end
        return [] if stdout.strip.empty?

        parsed = JSON.parse(stdout)
        Array(parsed['CommonPrefixes'])
      rescue StandardError => e
        log_debug("list-objects-v2 (delimited) parse failed: #{e.class}: #{e.message}")
        []
      end

      # Apply the TTL to a single PR branch. Deletes whole branch when
      # its newest ref is older than `cutoff`. Returns the count of
      # refs removed (0 when branch is alive).
      def maybe_prune_branch(branch_name, cutoff)
        tier_prefix = "#{PR_TIER}/#{branch_name}"
        refs = list_refs_in_tier(tier_prefix)
        return 0 if refs.empty?

        newest_ts = refs.first[1]
        return 0 if newest_ts >= cutoff

        delete_branch_prefix(tier_prefix, refs.length)
      end

      def parse_s3_timestamp(iso_string)
        Time.parse(iso_string).to_i
      rescue StandardError
        0
      end

      # ── AWS CLI shell-out ──────────────────────────────

      def aws_cp_silent(src, dst)
        run_aws('s3', 'cp', src, dst)
      end

      def aws_rm_recursive_silent(dst)
        run_aws('s3', 'rm', dst, '--recursive')
      end

      def list_objects(prefix)
        stdout, stderr, status = Open3.capture3(
          @cli_binary, 's3api', 'list-objects-v2',
          '--bucket', @bucket,
          '--prefix', "#{prefix}/",
          '--output', 'json'
        )
        unless status.success?
          log_debug("list-objects-v2 #{prefix} failed: #{stderr.chomp}")
          return []
        end
        return [] if stdout.strip.empty?

        parsed = JSON.parse(stdout)
        Array(parsed['Contents'])
      rescue StandardError => e
        log_debug("list-objects-v2 parse failed: #{e.class}: #{e.message}")
        []
      end

      def run_aws(*args)
        stdout, stderr, status = Open3.capture3(@cli_binary, *args)
        [status.success?, stdout, stderr]
      end

      # ── Logging ────────────────────────────────────────

      def log_debug(message)
        @logger&.debug("rspec-tracer remote_cache: #{message}")
      end

      def log_warn(message)
        @logger&.warn("rspec-tracer remote_cache: #{message}")
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
