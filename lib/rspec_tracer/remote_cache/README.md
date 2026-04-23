# Remote cache

Optional cross-machine cache layer — downloads a prior run's dependency
graph so a fresh checkout (CI, new contributor) starts warm.

## Responsibilities

- Download the cache for a given ref (commit SHA) into the local cache
  directory, with schema-version validation.
- Upload the current local cache under the branch ref.
- Persist branch refs so history rewrites (`git commit --amend`,
  `git pull -r`) don't invalidate the next run.
- Prune old entries per configured retention policy.

## Public protocol

```ruby
module RSpecTracer::RemoteCache::Backend
  REQUIRED_METHODS = %i[
    download upload branch_refs write_branch_refs prune!
  ].freeze

  def self.conforms?(backend); end
end
```

The shared-examples contract in
`spec/contracts/remote_cache_backend.rb` asserts the full behavioral
contract on every implementation.

## Layout (S3 backend)

Two-tier S3 layout with per-ref tar+gzip archives, paired with the
`schema_version` bump (1.x caches are refused cleanly; one cold run on
upgrade):

```
s3://<bucket>/<prefix>/
  main/<sha>/[<test_suite_id>/]cache.tar.gz
  pr/<branch>/<sha>/[<test_suite_id>/]cache.tar.gz
  pr/<branch>/branch_refs.json
```

Each `cache.tar.gz` packs `last_run.json` + the `<run_id>/` directory
(the 15-file local layout documented in `USER_FACING_SURFACE.md` §6).
Upload = 1 PUT; download = 1 GET. Local disk layout is unchanged
after unpack — external tooling that walks `rspec_tracer_cache/` still
sees the full 15-file breakdown.

Tier is determined from `$GIT_BRANCH` vs `$GIT_DEFAULT_BRANCH`. PR
downloads try their own `pr/<branch>/` tier first, then fall back to
`main/` for the same ref (catches cherry-picks from main).

## Shipped backends

- `S3Backend` — primary target, shell-out to `aws`/`awslocal` CLI.

## Planned backends (M7.2)

- `LocalFsBackend` — shared mount / NFS for on-prem CI.
- `RedisBackend` — ephemeral CI agents.

## User-facing surface

The Rakefile (`lib/rspec_tracer/remote_cache/Rakefile`) defines the
two tasks `rspec_tracer:remote_cache:download` and `:upload`. Users
load it from their own Rakefile:

```ruby
spec = Gem::Specification.find_by_name('rspec-tracer')
load "#{spec.gem_dir}/lib/rspec_tracer/remote_cache/Rakefile"
```

Env vars required: `GIT_DEFAULT_BRANCH`, `GIT_BRANCH`, and
`TEST_SUITE_ID` (optional; scopes the S3 path when set).
