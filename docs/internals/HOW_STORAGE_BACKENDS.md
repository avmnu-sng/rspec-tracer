# How storage backends work

Two on-disk storage backends ship in 2.0: `:json` (default;
preserves the 1.x 10-file layout) and `:sqlite` (single-file;
faster cold reads above ~5,000 examples). This doc walks the
on-disk shapes, the schema-version cold-run policy, and how the
backends compose with the optional MessagePack serializer.

## The protocol contract

`RSpecTracer::Storage::Backend` is a 5-method protocol:

```ruby
load_graph(schema_version:)         # -> Snapshot or nil
save_graph(snapshot, schema_version:)   # -> persists atomically
last_run_id                         # -> String or nil
transactional_save(&block)          # -> single-writer semantics
clear!                              # -> remove everything backend owns
```

The shared-examples group at
`spec/contracts/storage_backend.rb` exercises every requirement on
every shipping backend. JsonBackend is the legacy 1.x carry-forward;
SqliteBackend arrived in 2.0 to open up larger-suite scaling.

## JsonBackend — the 10-file layout

```
rspec_tracer_cache/
├── last_run.json               ← manifest pointer
└── <run_id>/
    ├── all_examples.json
    ├── duplicate_examples.json
    ├── interrupted_examples.json
    ├── flaky_examples.json
    ├── failed_examples.json
    ├── pending_examples.json
    ├── skipped_examples.json
    ├── all_files.json
    ├── dependency.json
    └── examples_coverage.json
```

**`last_run.json`** is the entry point. Holds:
- `schema_version` — Integer; current is 2.
- `run_id` — String; UUID-like ref to the per-run subdirectory.
- `timestamp` — ISO 8601 UTC.

The 10 per-run files under `<run_id>/` carry the dependency graph,
example registry, and coverage data. Each is a self-contained JSON
document the backend can load independently — useful for partial
recovery on disk corruption (one bad file doesn't poison the others).

The 1.x cache had 9 files (no `cache_hit_reason.json`); 2.0 added
this 10th file as a per-run aggregate of why each cached example
got reused. Documented as a 2.0 file-count bump in CHANGELOG.

### Atomic writes

`save_graph` writes via `transactional_save`'s block. Implementation
strategy: write each file to a `<name>.tmp` sibling, then rename
each into place after all writes succeed. A crash mid-save leaves
either the prior consistent state OR all 10 new files — never a
half-applied state.

### branch_refs lives separately

The remote-cache layer's `branch_refs.json` is NOT one of the 10
per-run files — it lives at
`<remote-cache-root>/branch-refs/<branch>/branch_refs.json` (per-
branch, not per-run). Backends that aggregate counts (e.g. file-
count validators) need to special-case it.

## SqliteBackend — the single-file layout

```
rspec_tracer_cache/
└── rspec_tracer.sqlite3
```

A single SQLite database file. Schema:

```sql
-- meta table: schema_version, run_id, timestamp (replaces last_run.json)
CREATE TABLE meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

-- per-run snapshots, one row per "save_graph" call
CREATE TABLE snapshots (
  run_id    TEXT PRIMARY KEY,
  data      BLOB NOT NULL,    -- msgpack-serialized snapshot
  timestamp INTEGER NOT NULL  -- Unix epoch
);
```

**Why msgpack and not JSON for the BLOB?** Two reasons:
1. **Size**: msgpack is ~30-40% smaller than JSON for the typical
   snapshot shape (lots of repeated string keys + small integer
   values).
2. **Speed**: msgpack deserializes faster than JSON's ad-hoc parser,
   especially for large nested hashes.

The `:json` backend can ALSO opt into msgpack via
`storage_backend :json, serializer: :msgpack`, but the
files-on-disk layout remains 10-file (each file becomes a `.msgpack`
binary instead of `.json` text).

### busy_timeout PRAGMA ordering

SQLite's PRAGMA ordering matters: `db.busy_timeout` MUST be set
BEFORE any write-locking PRAGMA (`journal_mode`, etc.), or
concurrent writers raise on the PRAGMA itself instead of waiting.

`SqliteBackend#initialize`:

```ruby
@db = SQLite3::Database.new(path)
@db.busy_timeout = 5_000  # FIRST
@db.execute('PRAGMA journal_mode = WAL')  # SECOND
```

Reversing this ordering would intermittently fail under
parallel_tests when two workers initialize their own SqliteBackend
instances against the same file.

### JRuby fallback

`sqlite3` gem has no `-java` platform variant. On JRuby:
- `Storage::SqliteBackend` raises `SqliteBackendError` on init.
- The engine catches it and falls back to JsonBackend with a
  one-time warn:
  ```
  rspec-tracer: SQLite storage backend unavailable on JRuby; using :json
  ```
- The warn fires at `Engine#setup` time so the user sees it before
  any example runs.

## Schema versioning + cold-run policy

`schema_version` is an integer field. Current: `2`. Stored:
- In `last_run.json` for JsonBackend.
- In the `meta` table for SqliteBackend.

When `load_graph(schema_version: N)` reads a cache whose
`schema_version` doesn't equal N (whether N+1 / N-1 / completely
different value), the backend:

1. Logs `cold run: cache schema_version mismatch (got X, want Y)`
   at info level.
2. Returns nil.

The engine treats `nil` as "no cache" — proceeds with a cold run +
writes a fresh schema-version-tagged manifest at finalize. No
migrators; users pay one cold run on schema bumps.

The schema bumps in 2.0 baseline (1.x cache becomes unreadable);
subsequent 2.x schema bumps are similar — old caches refuse, cold
run proceeds, new cache writes.

## How the engine talks to a backend

`Engine#setup`:

```ruby
backend = configuration.storage_backend_class.new(
  cache_path: configuration.cache_path,
  **configuration.storage_backend_opts
)
@previous_snapshot = backend.load_graph(
  schema_version: RSpecTracer::Storage::Schema::CURRENT
)
```

`Engine#finalize`:

```ruby
@storage_backend.transactional_save do
  @storage_backend.save_graph(
    @snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT
  )
end
```

Both Json + Sqlite backends accept the same constructor signature
(`cache_path:` + opts hash). The Configuration DSL's
`storage_backend(:json, ...)` resolves the symbol to the class
internally; user code never instantiates a backend directly.

## Custom storage backends

The protocol is small + the contract is exhaustive:

```ruby
class MyBackend
  def initialize(cache_path:, **opts)
    @cache_path = cache_path
    @opts = opts
  end

  def load_graph(schema_version:)
    # Return RSpecTracer::Storage::Snapshot or nil.
    # Nil = no cache OR schema mismatch.
    # Never raise on corruption — log + return nil.
  end

  def save_graph(snapshot, schema_version:)
    # Persist atomically. Either the whole save succeeds or none of it.
  end

  def last_run_id
    # Return the most-recent run_id, or nil.
  end

  def transactional_save(&block)
    # Yield with single-writer semantics; commit on clean exit;
    # roll back on raise.
    yield
  end

  def clear!
    # Remove everything this backend owns at @cache_path.
  end
end

RSpecTracer.configure do
  storage_backend MyBackend.new(cache_path: my_path, my_opt: 'value')
end
```

Wire your backend's spec into `spec/contracts/storage_backend.rb`'s
shared-examples group to verify the contract.

## Where to read code

- `lib/rspec_tracer/storage/backend.rb` — the protocol.
- `lib/rspec_tracer/storage/json_backend.rb` — JSON impl + `Merger`
  class for parallel_tests merge.
- `lib/rspec_tracer/storage/sqlite_backend.rb` — SQLite impl.
- `lib/rspec_tracer/storage/snapshot.rb` — the data class returned
  by `load_graph`.
- `lib/rspec_tracer/storage/lazy_snapshot.rb` — lazy-load wrapper
  for partial reads.
- `lib/rspec_tracer/storage/schema.rb` — `CURRENT` schema version
  constant.
- `spec/storage/json_backend_spec.rb` + `spec/storage/sqlite_backend_spec.rb`
  — unit tests.
- `spec/integration/coverage_json_round_trip_spec.rb` — byte-
  equivalence test for the coverage payload.
