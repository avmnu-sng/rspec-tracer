# frozen_string_literal: true

module RSpecTracer
  module RemoteCache
    # Protocol every remote-cache backend must satisfy. S3Backend,
    # LocalFsBackend, and RedisBackend all implement it. The shared-
    # examples group in `spec/contracts/remote_cache_backend.rb` asserts
    # the full contract on every implementation.
    #
    # Tier routing lives inside each backend, not in the protocol. A
    # backend is constructed with branch + default_branch + test_suite_id
    # state, and routes uploads/downloads to either the main tier
    # (`main/<sha>/...`) or the pr tier (`pr/<branch>/<sha>/...`) based
    # on whether the current branch is the default.
    #
    # Graceful-degradation contract (same as Storage::Backend):
    #   - `download(ref)` returns true/false, never raises on wire or
    #     validation failures. A failed download is "cold run" from the
    #     orchestrator's perspective.
    #   - `upload(ref)` raises on wire failure so the Rake task can
    #     report a meaningful exit status, but the orchestrator wraps
    #     the call in a rescue so test runs never propagate non-zero.
    #   - `branch_refs(branch_name)` returns `{}` when no refs file
    #     exists. Missing is not an error.
    #   - `write_branch_refs(branch_name, refs)` is a no-op for main
    #     tier writes (main branches do not use branch_refs; history
    #     rewrites are not expected on the default branch).
    #   - `prune!(...)` returns the count of refs removed and never
    #     raises on a LIST / DELETE wire error (logs + returns what it
    #     managed to delete). Scoped to the backend's own tier.
    #   - `prune_all!(pr_branch_ttl_seconds:)` walks every PR branch
    #     under the configured prefix, applies the ttl to each, and
    #     deletes dead branches whole. Cross-tier (every pr branch),
    #     unlike `prune!` which is own-tier only. Returns the count of
    #     refs removed across all branches. Never raises. No-op when
    #     ttl is nil / non-positive.
    #
    # This module is intentionally documentation-only - it does not
    # define stubs that raise NotImplementedError, because mutant would
    # flag every `raise` as an alive mutation with no way to kill it.
    # The shared-examples contract is the real gate.
    #
    # @example Registering a custom remote-cache backend
    #   RSpecTracer.configure do
    #     remote_cache_backend MyCustomBackend, custom_opt: 'value'
    #   end
    module Backend
      REQUIRED_METHODS = %i[
        download
        upload
        branch_refs
        write_branch_refs
        prune!
        prune_all!
      ].freeze

      # Verifies a candidate object satisfies the backend protocol.
      # Used by {RSpecTracer::Configuration#remote_cache_backend} to
      # gate custom-backend registration.
      #
      # @param backend [Object] candidate backend instance
      # @return [Boolean] true if every {REQUIRED_METHODS} entry is
      #   responded to
      def self.conforms?(backend)
        REQUIRED_METHODS.all? { |m| backend.respond_to?(m) }
      end
    end
  end
end
