# frozen_string_literal: true

module RSpecTracer
  module RemoteCache
    # Protocol every remote-cache backend must satisfy. S3Backend is the
    # only shipping implementation in M7.1; LocalFsBackend + RedisBackend
    # arrive in M7.2. The shared-examples group in
    # `spec/contracts/remote_cache_backend.rb` asserts the full contract
    # on every implementation.
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
    #     exists. Missing !=  error.
    #   - `write_branch_refs(branch_name, refs)` is a no-op for main
    #     tier writes (main branches don't use branch_refs — history
    #     rewrites are not expected on the default branch).
    #   - `prune!(...)` returns the count of refs removed and never
    #     raises on a LIST / DELETE wire error (logs + returns what it
    #     managed to delete).
    #
    # This module is intentionally documentation-only - it does not
    # define stubs that raise NotImplementedError, because mutant would
    # flag every `raise` as an alive mutation with no way to kill it.
    # The shared-examples contract is the real gate.
    module Backend
      REQUIRED_METHODS = %i[
        download
        upload
        branch_refs
        write_branch_refs
        prune!
      ].freeze

      def self.conforms?(backend)
        REQUIRED_METHODS.all? { |m| backend.respond_to?(m) }
      end
    end
  end
end
