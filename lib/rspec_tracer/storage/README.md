# Storage

Persistence layer for the dependency graph and per-example metadata.
Pluggable via a backend protocol.

## Responsibilities

- Load and save the dependency graph atomically.
- Enforce `schema_version` — refuse to load a cache outside the supported
  range. On mismatch: log, discard, fall back to cold boot. No
  migrators.
- Never propagate storage errors to the caller — corrupted or missing
  cache triggers a cold run, not a test-suite failure.

## Public protocol

```ruby
module RSpecTracer::Storage::Backend
  def load_graph(schema_version:); end
  def save_graph(graph, schema_version:); end
  def transactional_save(&block); end
end
```

## Planned backends

- `JsonBackend` — default, human-readable, diff-friendly.
- `SqliteBackend` — optional, for large suites where JSON load cost
  dominates.

## Status

Shipping in 2.0. The legacy 1.x persistence files
(`lib/rspec_tracer/cache.rb`, `report_writer.rb`, `coverage_writer.rb`)
were retired and replaced by this storage subsystem.
