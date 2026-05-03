# How remote-cache backends work

The remote-cache layer ships caches across CI workers + builds via
S3, the local filesystem, or Redis. This doc walks tier routing
(main vs PR), the candidate-ref walk, branch_refs, retention, and
the graceful-degradation contract.

## The protocol contract

`RSpecTracer::RemoteCache::Backend` is a 6-method protocol every
backend implements:

```ruby
download(ref)               # -> true/false; never raises on wire failure
upload(ref)                 # -> raises on wire failure
branch_refs(branch_name)    # -> Hash; {} when no refs file exists
write_branch_refs(branch_name, refs)  # -> no-op on main tier
prune!(...)                 # -> Integer (refs removed); never raises
prune_all!(pr_branch_ttl_seconds:)    # -> Integer; cross-tier; never raises
```

The shared-examples group at
`spec/contracts/remote_cache_backend.rb` exercises every requirement
on every shipping backend (S3 / LocalFS / Redis).

## Tier routing

A backend is constructed with branch + default_branch state:

```ruby
RemoteCache::S3Backend.new(
  bucket:         'my-bucket',
  prefix:         'rspec-tracer',
  branch:         'feat-new-thing',     # current build's branch
  default_branch: 'main',
  test_suite_id:  '3',                  # optional: from TEST_SUITE_ID
  local:          false,
  cache_path:     '/abs/path/to/cache'
)
```

The backend internally routes uploads + downloads to one of two
tiers based on `branch == default_branch`:

```
<prefix>/main/<commit-sha>/cache.tar.gz       ← main tier
<prefix>/pr/<branch>/<commit-sha>/cache.tar.gz ← pr tier
```

- **main tier**: history-strict; the `<commit-sha>` is the actual
  HEAD SHA. The 25-commit Git ancestry walk traverses recent main
  history to find the nearest viable cache.
- **pr tier**: per-branch; PR builds upload under `pr/<branch>/`
  so concurrent PRs don't collide. Falls back to main tier on a
  miss (the PR may not have its own cache yet).

`<test_suite_id>/` is appended after `<commit-sha>/` when
`TEST_SUITE_ID` is set, so sharded suites maintain separate caches.

## The candidate-ref walk on download

`download(ref)` doesn't just try the exact `ref`. It walks the
25-commit Git ancestry chain (`git rev-list --max-count=25 $ref`) +
the persisted branch_refs (last 25 commits seen on this branch
across recent runs), and tries each candidate ref until it finds
a usable cache or exhausts the list.

The order matters:
1. **Branch refs first** — the branch's own recent commits, which
   have the most relevant cache state (your latest pre-rebase
   work).
2. **Ancestry walk second** — main-line ancestors, which give
   "good enough" caches when the branch refs are exhausted (e.g.
   first run on a new branch).

For the PR tier, the candidate list is constructed against the PR
branch's refs; for the main tier, against `default_branch`.

The first candidate that:
- exists at the backend's storage location, AND
- has a valid `last_run.json` with the current `schema_version`,
- contains the expected file count for the suite

…wins. Subsequent candidates are skipped.

## branch_refs persistence (PR tier only)

Each PR-tier upload writes (or appends to) a `branch-refs/<branch>/
branch_refs.json` file:

```json
{
  "abc1234": 1700000000,
  "def5678": 1700000100
}
```

The keys are commit SHAs; values are committer Unix timestamps.
The file is appended to on each upload (with deduplication +
re-sorting by timestamp), capped at the last 25 entries per branch.

Why this exists: after a `git rebase main` on a PR branch, every
commit SHA changes. The Git ancestry walk for the new HEAD won't
find the pre-rebase caches because the SHAs are gone. branch_refs
remembers the SHAs across runs, so the post-rebase HEAD's download
walk still finds the pre-rebase cache.

Main tier doesn't need branch_refs because the default branch's
history doesn't get rewritten in normal usage.

## tree-SHA secondary index

In addition to the SHA-based primary lookup, S3Backend writes a
tree-SHA pointer at `<tier>/by_tree/<tree_sha>` on every upload (when
`tree_sha:` is passed). On download, if the requested commit-SHA
misses but the same tree-SHA was uploaded under a different commit,
the tree pointer resolves to that prior commit's archive.

Use case: rebases + reverts produce different commit-SHAs but the
SAME tree-SHA. Without the tree index, the post-rebase / post-
revert build pays a cold cache; with it, the cache hits via the tree
match.

## Retention

Three knobs in the configuration DSL:

- `cache_retention_count(N)` — keep the N most recent main-tier
  refs.
- `cache_retention_duration('7d')` — keep main-tier refs newer
  than the duration. Mutually exclusive with `cache_retention_count`.
- `cache_retention_pr_branch_ttl('48h')` — drop PR branches
  whose newest ref is older than the TTL. Independent of main
  tier (PR branches are typically short-lived).

`prune!` runs at upload time and prunes the backend's own tier.
`prune_all!` walks every PR branch under the configured prefix and
applies the TTL — used for periodic cross-tier cleanup (typically
called from a separate scheduled rake task, not on every CI run).

Both methods catch every `StandardError` and log + return what they
managed to delete; storage errors never propagate non-zero into the
test suite (graceful degradation).

## The three shipping backends

### S3Backend (`s3:`)

- Uses the `aws` (or `awslocal` when `local: true`) CLI for every
  operation. Matches 1.x's behavior; users with `aws configure`
  already done don't need to install a Ruby AWS SDK gem.
- Single tar.gz per ref containing the cache_path's full contents.
- LocalStack support via `local: true` + `awslocal` CLI on PATH.
- Requires AWS credentials (`AWS_ACCESS_KEY_ID` /
  `AWS_SECRET_ACCESS_KEY` env vars OR `~/.aws/credentials`).

### LocalFsBackend (`local_fs:`)

- Filesystem-backed. The "remote" is a local directory tree
  (typically a shared NFS / EFS mount).
- Same tier layout as S3Backend (`<root>/main/<sha>/cache.tar.gz`).
- Useful when you have shared filesystem across CI workers but no
  S3 bucket.

### RedisBackend (`redis:`)

- Uses `connection_pool` for thread-safe pooling.
- Cache contents are stored as Redis hash fields (DEL+HSET inside
  a `MULTI` for atomicity).
- Optional `ttl: <seconds>` on construction sets per-key EXPIRE
  inside the same MULTI; `nil` disables and falls back to user
  Redis eviction policy / explicit prune.
- PR-tier uploads also `SADD` into `<prefix>:pr_branches` (atomic
  with the cache write). Useful for ops dashboards: `SMEMBERS
  <prefix>:pr_branches` enumerates active PR branches without
  scanning the full key namespace.

## Graceful-degradation contract

Per `ARCHITECTURE.md`'s "Cache corruption recovery" + the
`Storage::Backend` contract: **rspec-tracer must never propagate a
remote-cache failure into the user's test suite**.

The `download!` orchestrator (in `RemoteCache::UserTasks`) wraps
every backend call in a rescue + log + return false. A failed
download is "cold run" from the user's perspective; tests proceed
normally.

The `upload!` path is similar: a failed upload is logged + warned
but doesn't change exit status. The tests already passed (or
already failed); the upload outcome shouldn't change that signal.

The Rake tasks at `lib/rspec_tracer/remote_cache/Rakefile` mirror
this contract — they print the orchestrator's log line and exit 0
even if the orchestrator returned false.

## When the cache decides "cold run"

Beyond the hard "no candidate found" case, the cache also falls
back to cold when:

- `last_run.json`'s `schema_version` doesn't match the current
  rspec-tracer version's expected schema. Logged as
  `"cold run: cache schema_version mismatch (got X, want Y)"`.
- The downloaded archive's file count doesn't match the expected
  per-suite count (`1 + N` for the manifest + per-run files).
  Logged as `"cold run: cache file count mismatch"`.
- The download attempt itself raised (network error, S3 403,
  Redis disconnect). Logged as the underlying error class +
  message.

## Custom backends

The protocol is small + the contract is well-specified. To register
a custom backend:

```ruby
RSpecTracer.configure do
  remote_cache_backend MyCustomBackend, my_opt: 'value'
end
```

Run the shared-examples group (`require
'spec/contracts/remote_cache_backend.rb'`) against your backend to
verify the contract. The 1.x → 2.0 cache schema cut is your
greenfield: backends never need to read 1.x layouts.

## Where to read code

- `lib/rspec_tracer/remote_cache/backend.rb` — the protocol
  module + REQUIRED_METHODS.
- `lib/rspec_tracer/remote_cache/s3_backend.rb` /
  `local_fs_backend.rb` / `redis_backend.rb` — implementations.
- `lib/rspec_tracer/remote_cache/git_ancestry.rb` — the candidate
  ref walk.
- `lib/rspec_tracer/remote_cache/user_tasks.rb` — the
  orchestrator the rake tasks call.
- `lib/rspec_tracer/remote_cache/Rakefile` — the user-facing
  rake task surface.
- `spec/integration/remote_cache_spec.rb` — S3 round-trip against
  LocalStack.
- `spec/integration/remote_cache_redis_spec.rb` — Redis round-trip.
- `spec/integration/remote_cache_local_fs_spec.rb` — Local-FS
  round-trip.
- `spec/integration/rake_remote_cache_spec.rb` — the
  user-facing rake task surface end-to-end.
