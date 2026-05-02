# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'securerandom'

require_relative 'archive'
require_relative 'backend'
require_relative 'validator'

module RSpecTracer
  module RemoteCache
    # Filesystem implementation of `RemoteCache::Backend`. Target is
    # a shared directory: an NFS mount, a per-host dev cache, or a CI
    # workspace volume. Two-tier layout mirrors `S3Backend` bit-for-bit;
    # a LocalFs root directory can be rsync'd to/from S3 without any
    # transform (same `cache.tar.gz` per ref, same `branch_refs.json`
    # path, same tier prefixes).
    #
    #   <root>/main/<sha>/[<test_suite_id>/]cache.tar.gz
    #   <root>/pr/<branch>/<sha>/[<test_suite_id>/]cache.tar.gz
    #   <root>/pr/<branch>/branch_refs.json
    #
    # Uploads are atomic: the archive is staged at a sibling tmp path
    # on the same filesystem, then `File.rename`d into place. POSIX
    # rename is atomic on same-filesystem moves, which covers every
    # shared-mount topology LocalFs targets.
    #
    # Concurrent writes to the same ref: last-write-wins is correct
    # because the archive content is a deterministic function of the
    # local cache (two workers on the same SHA produce identical bytes).
    # No file locking - flock is unreliable over NFS (lockd sharp
    # edges) and buys nothing when contents match.
    #
    # NFS caveat: on a network filesystem, cross-node consistency is
    # eventual. A download issued by node B immediately after an upload
    # on node A may miss; retries converge. Document as user concern,
    # not a backend correctness issue.
    class LocalFsBackend
      class LocalFsBackendError < StandardError; end

      MAIN_TIER = 'main'
      PR_TIER = 'pr'
      BRANCH_REFS_FILENAME = 'branch_refs.json'
      LAST_RUN_FILENAME = 'last_run.json'
      CACHE_ARCHIVE_FILENAME = Archive::CACHE_FILENAME
      ENCODING = 'UTF-8'

      # rubocop:disable Metrics/ParameterLists
      def initialize(root:, branch:, default_branch:, cache_path:,
                     test_suite_id: nil, logger: nil)
        validate_required!(root: root, branch: branch,
                           default_branch: default_branch, cache_path: cache_path)

        @root = File.expand_path(root.to_s)
        @branch = branch.to_s.chomp
        @default_branch = default_branch.to_s.chomp
        @test_suite_id = normalize_test_suite_id(test_suite_id)
        @cache_path = cache_path.to_s
        @logger = logger
      end
      # rubocop:enable Metrics/ParameterLists

      # Download the cache for `ref` into `cache_path`. Tries the
      # backend's own tier first; on miss, falls back to the main tier
      # for the same ref. Validates via `schema_version` before
      # declaring success. Returns true on validated success, false
      # otherwise. Cleans up partially-extracted state on failure.
      #
      # `tree_sha:` is accepted for protocol uniformity with S3Backend
      # but is currently a no-op: the tree-SHA secondary index is an
      # S3-only feature (M8.4-B). Future enhancement may extend it
      # here; the orchestrator already forwards the kwarg.
      def download(ref, tree_sha: nil)
        _ = tree_sha
        return false if blank?(ref)

        tiers_to_try = [own_tier_prefix]
        tiers_to_try << main_tier_prefix if pr_tier?

        tiers_to_try.any? { |tier| try_download_from(tier, ref) }
      end

      # Upload the local cache to this backend's own tier under `ref`.
      # Packs the 15-file local layout into a `cache.tar.gz` via
      # `Archive.pack`, renames into place atomically. Raises on a
      # malformed local cache or an I/O failure.
      #
      # `tree_sha:` is accepted for protocol uniformity with S3Backend
      # (no-op here; see `download`).
      def upload(ref, tree_sha: nil)
        _ = tree_sha
        raise LocalFsBackendError, 'ref is required' if blank?(ref)

        run_id = read_local_run_id
        raise LocalFsBackendError, "no local cache to upload (missing #{LAST_RUN_FILENAME})" if run_id.nil?

        dest = archive_path(own_tier_prefix, ref)
        FileUtils.mkdir_p(File.dirname(dest))
        staging = "#{dest}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
        begin
          Archive.pack(cache_path: @cache_path, run_id: run_id, dest_path: staging)
          File.rename(staging, dest)
          log_debug("uploaded cache for #{ref} to #{own_tier_prefix} (#{File.size(dest)} bytes)")
        ensure
          FileUtils.rm_f(staging)
        end
      end

      # Read branch_refs for the given branch. Returns `{sha => ts_epoch}`
      # or `{}` on missing / malformed. PR tier only.
      def branch_refs(branch_name)
        return {} if blank?(branch_name)

        path = branch_refs_path(branch_name)
        return {} unless File.file?(path)

        parsed = JSON.parse(File.read(path, encoding: ENCODING))
        parsed.is_a?(Hash) ? parsed.transform_values(&:to_i) : {}
      rescue StandardError => e
        log_debug("branch_refs read failed (#{e.class}: #{e.message}); treating as empty")
        {}
      end

      # Persist branch_refs for the given branch. No-op for main-branch
      # writes. Atomic via tmp+rename. Raises on I/O failure for PR
      # tier.
      def write_branch_refs(branch_name, refs)
        return if blank?(branch_name)
        return if branch_name.to_s.chomp == @default_branch
        return if refs.nil? || refs.empty?

        path = branch_refs_path(branch_name)
        FileUtils.mkdir_p(File.dirname(path))
        staging = "#{path}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
        begin
          File.write(staging, JSON.pretty_generate(refs), encoding: ENCODING)
          File.rename(staging, path)
          log_debug("wrote branch_refs for #{branch_name}")
        ensure
          FileUtils.rm_f(staging)
        end
      end

      # Apply retention to the backend's own tier. Returns count removed.
      # Semantics match S3Backend: count keeps newest N, duration prunes
      # by mtime, pr_branch_ttl deletes the whole branch prefix when
      # idle. Two or more params may be set simultaneously; all nil/0
      # is a no-op. Never raises on partial I/O failure.
      def prune!(count: nil, duration_seconds: nil, pr_branch_ttl_seconds: nil)
        removed = 0
        removed += prune_by_count!(count) if count&.positive?
        removed += prune_by_duration!(duration_seconds) if duration_seconds&.positive?
        removed += prune_dead_pr_branch!(pr_branch_ttl_seconds) if pr_tier? && pr_branch_ttl_seconds&.positive?
        removed
      end

      # Cross-tier PR-branch cleanup. Enumerates every branch dir under
      # `pr/`, applies the ttl to each, deletes branches with no ref
      # newer than the cutoff. Returns total refs removed. No-op on
      # nil / non-positive ttl.
      def prune_all!(pr_branch_ttl_seconds: nil)
        return 0 unless pr_branch_ttl_seconds&.positive?

        cutoff = Time.now.to_i - pr_branch_ttl_seconds.to_i
        pr_root = File.join(@root, PR_TIER)
        return 0 unless File.directory?(pr_root)

        branch_dirs(pr_root).sum { |branch_dir| maybe_prune_branch(branch_dir, cutoff) }
      end

      # Warn when the main tier has grown beyond a soft threshold and
      # no retention is configured. Called from the orchestrator.
      def unbounded_warning(warn_threshold: 500)
        refs = list_refs_in_tier(MAIN_TIER)
        return nil unless refs.length > warn_threshold

        "rspec-tracer remote cache has #{refs.length} refs in #{@root}/#{MAIN_TIER}; " \
          'configure cache_retention_count or cache_retention_duration to cap growth'
      end

      private

      def blank?(value)
        value.nil? || value.to_s.empty?
      end

      def validate_required!(**opts)
        opts.each do |key, value|
          raise LocalFsBackendError, "#{key} is required" if blank?(value)
        end
      end

      def normalize_test_suite_id(raw)
        return nil if raw.nil?

        value = raw.to_s
        value.empty? ? nil : value
      end

      def pr_tier?
        @branch != @default_branch
      end

      def own_tier_prefix
        pr_tier? ? "#{PR_TIER}/#{@branch}" : MAIN_TIER
      end

      def main_tier_prefix
        MAIN_TIER
      end

      def archive_path(tier_prefix, ref)
        File.join(*[@root, tier_prefix, ref, @test_suite_id, CACHE_ARCHIVE_FILENAME].compact)
      end

      def ref_dir(tier_prefix, ref)
        File.join(@root, tier_prefix, ref)
      end

      def tier_dir(tier_prefix)
        File.join(@root, tier_prefix)
      end

      def branch_refs_path(branch_name)
        File.join(@root, PR_TIER, branch_name.chomp, BRANCH_REFS_FILENAME)
      end

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
        return nil if blank?(run_id)

        run_id
      rescue StandardError
        nil
      end

      # Attempt extraction from (tier_prefix, ref). Returns true on
      # validated success. Rolls back any partially-extracted state on
      # failure so the next caller doesn't observe half-landed cache.
      # rubocop:disable Naming/PredicateMethod
      def try_download_from(tier_prefix, ref)
        src = archive_path(tier_prefix, ref)
        return false unless File.file?(src)

        extract_and_validate(src, tier_prefix, ref)
      end

      def extract_and_validate(src, tier_prefix, ref)
        begin
          Archive.extract(archive_path: src, dest_dir: @cache_path)
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

      # Enumerate refs in `tier_prefix` as Array<[ref, mtime_epoch]>,
      # newest-first. Uses the archive's mtime as the timestamp proxy -
      # a fresh upload overwrites the archive via atomic rename so
      # mtime tracks upload time correctly.
      def list_refs_in_tier(tier_prefix)
        dir = tier_dir(tier_prefix)
        return [] unless File.directory?(dir)

        refs = []
        Dir.each_child(dir) do |ref|
          archive = archive_path(tier_prefix, ref)
          next unless File.file?(archive)

          refs << [ref, File.mtime(archive).to_i]
        end
        refs.sort_by { |_, ts| -ts }
      end

      def prune_by_count!(count)
        refs = list_refs_in_tier(own_tier_prefix)
        return 0 if refs.length <= count

        to_delete = refs[count..] || []
        delete_refs(to_delete.map(&:first), own_tier_prefix)
      end

      def prune_by_duration!(duration_seconds)
        cutoff = Time.now.to_i - duration_seconds.to_i
        stale = list_refs_in_tier(own_tier_prefix).select { |_, ts| ts < cutoff }.map(&:first)
        delete_refs(stale, own_tier_prefix)
      end

      def delete_refs(refs, tier_prefix)
        removed = 0
        refs.each do |ref|
          FileUtils.rm_rf(ref_dir(tier_prefix, ref))
          removed += 1
          log_debug("pruned ref #{tier_prefix}/#{ref}")
        rescue StandardError => e
          log_warn("failed to prune ref #{tier_prefix}/#{ref}: #{e.class}: #{e.message}")
        end
        removed
      end

      def prune_dead_pr_branch!(ttl_seconds)
        refs = list_refs_in_tier(own_tier_prefix)
        return 0 if refs.empty?

        newest_ts = refs.first[1]
        return 0 if newest_ts >= Time.now.to_i - ttl_seconds.to_i

        delete_branch_prefix(own_tier_prefix, refs.length)
      end

      # Delete every descendant of `<root>/<tier_prefix>` (cache dirs +
      # branch_refs.json). Returns the supplied `ref_count` on success,
      # 0 on failure.
      def delete_branch_prefix(tier_prefix, ref_count)
        FileUtils.rm_rf(tier_dir(tier_prefix))
        log_debug("pruned dead PR branch #{tier_prefix}")
        ref_count
      rescue StandardError => e
        log_warn("failed to prune dead PR branch #{tier_prefix}: #{e.class}: #{e.message}")
        0
      end

      def branch_dirs(pr_root)
        Dir.each_child(pr_root)
          .map { |name| File.join(pr_root, name) }
          .select { |path| File.directory?(path) }
      end

      # Apply the TTL to a single PR branch dir. Deletes whole branch
      # when its newest ref is older than cutoff. Returns the count of
      # refs removed (0 when branch is alive).
      def maybe_prune_branch(branch_dir, cutoff)
        branch_name = File.basename(branch_dir)
        tier_prefix = "#{PR_TIER}/#{branch_name}"
        refs = list_refs_in_tier(tier_prefix)
        return 0 if refs.empty?

        newest_ts = refs.first[1]
        return 0 if newest_ts >= cutoff

        delete_branch_prefix(tier_prefix, refs.length)
      end

      def log_debug(message)
        @logger&.debug("rspec-tracer remote_cache: #{message}")
      end

      def log_warn(message)
        @logger&.warn("rspec-tracer remote_cache: #{message}")
      end
    end
  end
end
