# frozen_string_literal: true

require 'time'
require 'uri'

require_relative 'git_ancestry'
require_relative 'local_fs_backend'
require_relative 'redis_backend'
require_relative 's3_backend'

module RSpecTracer
  module RemoteCache
    # Orchestrator for the user-facing `rspec_tracer:remote_cache:*`
    # Rake tasks. Composes `GitAncestry` + a `Backend` implementation,
    # drives the download (candidate-ref walk + first-valid wins) and
    # upload (branch_ref + branch_refs update + retention prune) flows.
    #
    # Called from `lib/rspec_tracer/remote_cache/Rakefile` which is
    # loaded by the user's own Rakefile per USER_FACING_SURFACE.md §5.
    # The user-facing task surface is preserved from 1.x bit-for-bit:
    # same task names, same env vars, same exit behavior.
    #
    # Graceful-degradation contract:
    #   - `download!` catches every StandardError, logs, returns false.
    #     A failed download is cold run; tests still proceed.
    #   - `upload!` catches every StandardError, logs, returns false.
    #     A failed upload is logged but doesn't propagate non-zero -
    #     the tests already passed; cache miss is recoverable next run.
    #
    class UserTasks
      BUILT_IN_BACKENDS = {
        s3: S3Backend,
        local_fs: LocalFsBackend,
        redis: RedisBackend
      }.freeze

      def self.download!(configuration: RSpecTracer, env: ENV)
        new(configuration: configuration, env: env).download!
      end

      def self.upload!(configuration: RSpecTracer, env: ENV)
        new(configuration: configuration, env: env).upload!
      end

      def self.prune_all!(configuration: RSpecTracer, env: ENV)
        new(configuration: configuration, env: env).prune_all!
      end

      def self.git_repo?
        system('git', 'rev-parse', 'HEAD', out: File::NULL, err: File::NULL)
      end

      def initialize(configuration:, env:)
        @config = configuration
        @env = env
        @logger = configuration.logger
      end

      def download!
        ancestry = build_ancestry
        ancestry.merge_base_branch!
        backend = build_backend(ancestry)

        refs = candidate_refs(ancestry, backend)
        if refs.empty?
          @logger.warn 'rspec-tracer remote_cache: no cache candidates found; cold run'
          return false
        end

        refs.each do |ref|
          @logger.debug "rspec-tracer remote_cache: trying ref #{ref}"
          return true if backend.download(ref)
        end

        @logger.warn 'rspec-tracer remote_cache: no suitable cache found; cold run'
        false
      rescue StandardError => e
        @logger.warn "rspec-tracer remote_cache: download failed (#{e.class}: #{e.message}); cold run"
        false
      end

      def upload!
        ancestry = build_ancestry
        ancestry.merge_base_branch!
        backend = build_backend(ancestry)

        backend.upload(ancestry.branch_ref)
        maybe_update_branch_refs(backend, ancestry)
        maybe_prune(backend, ancestry)
        maybe_warn_unbounded(backend)
        true
      rescue StandardError => e
        @logger.warn "rspec-tracer remote_cache: upload failed (#{e.class}: #{e.message})"
        false
      end

      # Cross-tier PR-branch prune. Walks every branch under the
      # configured prefix and deletes whole branches idle longer than
      # `cache_retention_pr_branch_ttl_seconds`. Designed as a periodic
      # maintenance task (nightly cron) - dead PR branches whose tip is
      # never re-uploaded otherwise accumulate forever because
      # `maybe_prune` only scopes to the current upload's tier. Returns
      # the total refs removed across all branches, or 0 on graceful
      # failure.
      def prune_all!
        ttl = safe_config(:cache_retention_pr_branch_ttl_seconds)
        if ttl.nil?
          @logger.warn 'rspec-tracer remote_cache: prune_all requires cache_retention_pr_branch_ttl; skipping'
          return 0
        end

        backend = build_backend(build_admin_ancestry)
        removed = backend.prune_all!(pr_branch_ttl_seconds: ttl)
        @logger.debug "rspec-tracer remote_cache: prune_all removed #{removed} refs"
        removed
      rescue StandardError => e
        @logger.warn "rspec-tracer remote_cache: prune_all failed (#{e.class}: #{e.message})"
        0
      end

      private

      def build_ancestry
        GitAncestry.new(
          default_branch: require_env('GIT_DEFAULT_BRANCH'),
          branch: require_env('GIT_BRANCH')
        )
      end

      # Ancestry for cross-tier admin tasks (prune_all). Only
      # GIT_DEFAULT_BRANCH is required; GIT_BRANCH defaults to it so
      # the backend constructs in main-tier mode (prune_all walks every
      # pr/ branch regardless of the backend's own tier, so the branch
      # value does not affect behavior). Running prune_all from a
      # cron/workflow that is not tied to a specific PR should work
      # with just GIT_DEFAULT_BRANCH set.
      def build_admin_ancestry
        default = require_env('GIT_DEFAULT_BRANCH')
        branch = @env['GIT_BRANCH']
        branch = default if branch.nil? || branch.to_s.empty?
        GitAncestry.new(default_branch: default, branch: branch)
      end

      def require_env(name)
        value = @env[name]
        raise "#{name} environment variable is not set" if value.nil? || value.to_s.empty?

        value
      end

      def build_backend(ancestry)
        entry = remote_cache_backend_entry
        raise 'no remote_cache_backend configured' if entry.nil?

        name_or_class, user_opts = entry
        klass = resolve_backend_class(name_or_class)
        klass.new(**merge_runtime_opts(user_opts, ancestry))
      end

      def remote_cache_backend_entry
        explicit = safe_config(:remote_cache_backend_entry)
        return explicit if explicit

        derive_from_legacy_dsl
      end

      def derive_from_legacy_dsl
        s3_uri = safe_config(:reports_s3_path)
        return nil if s3_uri.nil? || s3_uri.to_s.empty?

        uri = URI.parse(s3_uri)
        return nil unless uri.scheme == 's3' && uri.host && !uri.host.empty?

        prefix = uri.path.to_s.sub(%r{^/}, '')
        [
          :s3,
          {
            bucket: uri.host,
            prefix: prefix,
            local: safe_config(:use_local_aws) == true
          }
        ]
      end

      def resolve_backend_class(name_or_class)
        case name_or_class
        when Symbol
          BUILT_IN_BACKENDS.fetch(name_or_class) do
            raise "unknown remote_cache_backend: #{name_or_class.inspect}"
          end
        when Class
          name_or_class
        else
          raise "invalid remote_cache_backend: #{name_or_class.class}"
        end
      end

      def merge_runtime_opts(user_opts, ancestry)
        runtime = {
          branch: ancestry.branch_name,
          default_branch: ancestry.default_branch_name,
          cache_path: @config.cache_path,
          test_suite_id: @env['TEST_SUITE_ID'],
          logger: @logger
        }
        # User opts win for bucket/prefix/local; runtime opts are injected
        # fresh (caller never sets these via DSL).
        runtime.merge(user_opts)
      end

      def candidate_refs(ancestry, backend)
        refs = {}
        refs.merge!(backend.branch_refs(ancestry.branch_name)) if ancestry.pr_build?
        refs.merge!(ancestry.ancestry_refs)
        refs.sort_by { |_, ts| -ts }.map(&:first)
      end

      def maybe_update_branch_refs(backend, ancestry)
        return unless ancestry.pr_build?

        existing = backend.branch_refs(ancestry.branch_name)
        updated = existing.merge(ancestry.branch_ref => Time.now.to_i)
        filtered = filter_branch_refs(updated, ancestry)
        backend.write_branch_refs(ancestry.branch_name, filtered)
      end

      # Bound branch_refs to 25 most-recent, filtered to refs newer
      # than the oldest ancestry commit when ancestry is non-empty.
      # Matches 1.x `Repo#filter_branch_refs`.
      def filter_branch_refs(refs, ancestry)
        ancestry_refs = ancestry.ancestry_refs
        bounded =
          if ancestry_refs.empty?
            refs.sort_by { |_, ts| -ts }.first(GitAncestry::ANCESTRY_DEPTH)
          else
            oldest_ts = ancestry_refs.values.min
            refs
              .select { |_, ts| ts >= oldest_ts }
              .sort_by { |_, ts| -ts }
              .first(GitAncestry::ANCESTRY_DEPTH)
          end
        bounded.to_h
      end

      # Retention knob routing per approved scope:
      #   - `cache_retention_count` / `cache_retention_duration`
      #     apply to the main tier only. Main accumulates linearly;
      #     these cap it.
      #   - `cache_retention_pr_branch_ttl` applies to PR tier only.
      #     PR branches die after merge; TTL prunes the whole branch
      #     prefix when it's been idle.
      def maybe_prune(backend, ancestry)
        return unless backend.respond_to?(:prune!)

        opts = retention_opts_for(ancestry)
        return if opts.values.all?(&:nil?)

        removed = backend.prune!(**opts)
        @logger.debug "rspec-tracer remote_cache: pruned #{removed} refs" if removed.positive?
      end

      def retention_opts_for(ancestry)
        if ancestry.pr_build?
          { count: nil, duration_seconds: nil,
            pr_branch_ttl_seconds: safe_config(:cache_retention_pr_branch_ttl_seconds) }
        else
          { count: safe_config(:cache_retention_count),
            duration_seconds: safe_config(:cache_retention_duration_seconds),
            pr_branch_ttl_seconds: nil }
        end
      end

      def maybe_warn_unbounded(backend)
        return unless backend.respond_to?(:unbounded_warning)
        # Only meaningful on the main tier - PR tier gets branch-TTL
        # retention and is bounded by branch lifecycle.
        return if safe_config(:cache_retention_count)
        return if safe_config(:cache_retention_duration_seconds)

        warning = backend.unbounded_warning
        @logger.warn(warning) if warning
      end

      def safe_config(method)
        @config.public_send(method)
      rescue NoMethodError
        nil
      end
    end
  end
end
