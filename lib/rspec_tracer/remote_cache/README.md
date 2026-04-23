# Remote cache

Optional cross-machine cache layer. Downloads a prior run's dependency
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
    download upload branch_refs write_branch_refs prune! prune_all!
  ].freeze

  def self.conforms?(backend); end
end
```

The shared-examples contract in `spec/contracts/remote_cache_backend.rb`
asserts the full behavioral contract on every implementation.

## Shipped backends

All three share the two-tier layout (main + per-PR-branch), the same
schema_version validator, and the same retention knobs.

- **`S3Backend`** — primary target. Shells out to `aws` / `awslocal`
  CLI. Cache is one `cache.tar.gz` per ref.
- **`LocalFsBackend`** — shared directory (NFS, dev cache, CI
  workspace). Same `cache.tar.gz` archive format as S3 — a LocalFs
  root can be rsync'd to/from S3 with no transform. Atomic uploads via
  tmp-write + rename. No locking (unreliable over NFS; last-write-wins
  on same SHA is correct because archive bytes are deterministic).
- **`RedisBackend`** — each ref stored as a Redis hash (field-per-file)
  keyed under `<prefix>:main:<sha>` / `<prefix>:pr:<branch>:<sha>`.
  `redis` gem is an OPTIONAL dependency — users add it to their own
  Gemfile. A missing gem logs a clear warning and falls back to a cold
  run instead of crashing the test suite.

## Layout

### S3 / LocalFS (archive-per-ref)

```
<root>/main/<sha>/[<test_suite_id>/]cache.tar.gz
<root>/pr/<branch>/<sha>/[<test_suite_id>/]cache.tar.gz
<root>/pr/<branch>/branch_refs.json
```

(`<root>` is `s3://<bucket>/<prefix>` for S3, a local/NFS path for
LocalFs.) Each `cache.tar.gz` packs `last_run.json` + the `<run_id>/`
directory (the 15-file local layout documented in
`USER_FACING_SURFACE.md` §6). Upload = 1 PUT; download = 1 GET. Local
disk layout is unchanged after unpack — external tooling that walks
`rspec_tracer_cache/` still sees the full 15-file breakdown.

### Redis (hash-per-ref)

```
<prefix>:main:<sha>[:<test_suite_id>]           -> HASH
<prefix>:pr:<branch>:<sha>[:<test_suite_id>]    -> HASH
<prefix>:pr:<branch>:branch_refs                -> STRING (JSON)
```

Hash fields: `_timestamp` (epoch), `last_run.json`, and one field per
file in the 15-file layout (`<run_id>/<file>.json`). Keeps Redis-native
inspection (`HGETALL`, `HKEYS`) usable without extracting an archive.

## Tier routing

Tier is determined from `$GIT_BRANCH` vs `$GIT_DEFAULT_BRANCH`. PR
builds write to the PR tier; main builds write to the main tier. PR
downloads try their own tier first, then fall back to main tier for
the same ref (catches cherry-picks from main).

## User-facing surface

The Rakefile (`lib/rspec_tracer/remote_cache/Rakefile`) defines three
tasks:

- `rspec_tracer:remote_cache:download`
- `rspec_tracer:remote_cache:upload`
- `rspec_tracer:remote_cache:prune_all` — maintenance task that walks
  every PR branch and drops ones idle longer than
  `cache_retention_pr_branch_ttl`. Intended for a nightly cron.

Users load the Rakefile from their own Rakefile:

```ruby
spec = Gem::Specification.find_by_name('rspec-tracer')
load "#{spec.gem_dir}/lib/rspec_tracer/remote_cache/Rakefile"
```

Env vars: `GIT_DEFAULT_BRANCH` (required), `GIT_BRANCH` (required for
download/upload; defaults to `GIT_DEFAULT_BRANCH` for prune_all), and
`TEST_SUITE_ID` (optional; scopes the cache key when set).

## Configuration

Shortest path — one `remote_cache_uri` call:

```ruby
RSpecTracer.configure do
  remote_cache_uri 's3://my-bucket/rspec-tracer'
  # or: remote_cache_uri 'file:///mnt/shared-cache'
  # or: remote_cache_uri 'redis://redis.internal:6379/0'
  cache_retention_count 100            # keep newest N on main tier
  cache_retention_pr_branch_ttl '14 days' # idle-branch cutoff on pr tier
end
```

Structured form for cases the URI cannot express:

```ruby
RSpecTracer.configure do
  remote_cache_backend :s3,       bucket: 'my-bucket', prefix: 'rspec-tracer'
  # or:
  remote_cache_backend :local_fs, root: '/mnt/shared-cache'
  # or:
  remote_cache_backend :redis,    url: ENV.fetch('REDIS_URL'), prefix: 'rspec-tracer'
end
```

## Caveats

- **LocalFS over NFS**: cross-node consistency is eventual. A
  download issued by node B immediately after an upload on node A may
  miss; retries converge. Not a backend correctness bug.
- **Redis memory**: hash-per-ref without gzip compression uses ~2-5x
  more bytes than the S3/LocalFS tar+gzip archive. Fine for realistic
  cache sizes (a few hundred refs × ~100 KB raw); budget Redis memory
  accordingly for very large fleets.
