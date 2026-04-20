# Remote cache

Optional cross-machine cache layer — downloads a prior run's dependency
graph so a fresh checkout (CI, new contributor) starts warm.

## Responsibilities

- Download the cache for a given ref (branch, commit, tag).
- Upload the current local cache under a ref.
- List available refs, newest first.

## Public protocol

```ruby
module RSpecTracer::RemoteCache::Backend
  def download(ref); end
  def upload(ref); end
  def list_refs; end
end
```

## Planned backends

- `S3Backend` — primary target.
- `LocalFsBackend` — shared mount / NFS.
- `RedisBackend` — optional, for ephemeral CI agents.

## Status

This directory currently holds the 1.x remote-cache implementation
(`aws.rb`, `cache.rb`, `repo.rb`, `validator.rb`, `Rakefile`). The 2.0
backend-protocol split lands in Phase 7 (session M7.1). Legacy code and
2.0 protocol will coexist here during the transition; legacy files are
removed once M7.1 ships.
