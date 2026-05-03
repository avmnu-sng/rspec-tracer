# rspec-tracer 2.0 — Architecture

## Mental model

> **A test is a pure function of its inputs. Our job is to identify every
> input and hash it.**

This is the load-bearing abstraction. Internalize it and every design decision
falls out naturally.

- "Dependency tracking" → input identification
- "Cache invalidation" → input-digest mismatch
- "Skipping tests" → change set empty for this example
- "Flaky test" → same inputs, different outputs (by definition)
- "Monorepo support" → multiple input scopes
- "Parallel CI sharding" → partition examples by input-hash modulo N
- "Coverage blind spot" → unidentified input

Any feature we can't express as "identifying an input" or "comparing a digest"
is either not our problem or an escape hatch.

## Input taxonomy

Every test has zero or more inputs from these buckets:

1. **Ruby-executed source** — `.rb` files whose code ran during the test.
   *Observed via:* Ruby's `Coverage` module. Cost: near-zero (C-level bitmap).

2. **File I/O performed by Ruby** — `File.read`, `YAML.load_file`,
   `JSON.load_file`, `IO.read`, and their kin.
   *Observed via:* `Module#prepend` hooks on the singleton classes of `File`,
   `IO`, `YAML`, `JSON`, `Kernel`. Cost: ~100–300 ns per call.

3. **Framework events** — Rails template renders, I18n lookups, etc.
   *Observed via:* `ActiveSupport::Notifications` subscribers. Cost: already
   paid by Rails; we just listen.

4. **Declared globs** — inputs the user explicitly tells us to track, e.g.
   `config/locales/**/*.yml`, `db/schema.rb`, `Gemfile.lock`.
   *Observed via:* directory walk at boot, digest cache, declared-to-example
   attribution rules. Cost: proportional to declared files, ~O(20 ms) at
   boot.

5. **Whole-suite invalidators** — inputs whose change invalidates every
   example: `Gemfile.lock`, `.ruby-version`, the `.rspec-tracer` config file,
   the `rspec-tracer` gem version itself.
   *Observed via:* digest check at boot; any mismatch forces full run.

6. **Truly unobservable inputs** — ENV-var branches that changed without any
   file change; refinements in files that never executed; monkey-patches in
   gems under filtered paths.
   *Handled via:* explicit escape hatch. User can declare
   `track_env 'DATABASE_URL'` or tag an example with
   `tracks: { env: 'FEATURE_X' }`. If they don't, we can't detect it — but
   we document the limitation.

**Rule:** every input type has exactly one observation mechanism. No
duplication, no overlap. If the user declares a glob that covers the same
files we auto-intercept, the declared glob takes precedence (deterministic).

### Input kinds (closed enum)

The 6 buckets above project onto an 8-symbol enum on
`RSpecTracer::Tracker::Input#kind`:

| Bucket                              | `:kind` symbol(s)              |
|-------------------------------------|--------------------------------|
| 1. Ruby-executed source             | `:ruby`                        |
| 2. File I/O performed by Ruby       | `:data`, `:schema`             |
| 3. Framework events                 | `:template`, `:notification`   |
| 4. Declared globs                   | `:declared`                    |
| 5. Whole-suite invalidators         | `:lockfile`                    |
| 6. Truly unobservable inputs        | `:env` (escape-hatch metadata) |

Closed-enum (`ALLOWED_INPUT_KINDS` in `lib/rspec_tracer/tracker/input.rb`),
validated in the constructor — typos raise. Adding a kind is a one-line
change plus a test; shrinking the set is a `schema_version` bump.

`:schema` is split out from `:data` because Rails `db/schema.rb`
changes invalidate any test that touches the database — useful as a
distinct kind for the dependency-graph reasoning. `:notification` is
split out from `:template` because not every framework event is a
template render (I18n lookups, ActiveRecord query introspection,
etc.) and we want each observer to tag its kind narrowly.

## Layer structure

```text
┌────────────────────────────────────────────────────────────────────┐
│                         CLI (bin/rspec-tracer)                      │
├────────────────────────────────────────────────────────────────────┤
│                 RSpec integration (lib/.../rspec/)                  │
│        (hooks, filter, parallel_tests glue, metadata DSL)           │
├────────────────────────────────────────────────────────────────────┤
│                   Tracker (lib/.../tracker/)                        │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌───────────┐  │
│  │  Coverage    │ │    I/O       │ │  Notifs      │ │ Declared  │  │
│  │  adapter     │ │   hooks      │ │ (ActionView) │ │   globs   │  │
│  └──────┬───────┘ └──────┬───────┘ └──────┬───────┘ └─────┬─────┘  │
│         └────────────────┴─────────────────┴──────────────┘        │
│                              │                                     │
│                    ┌─────────▼────────┐                             │
│                    │ Dependency graph │                             │
│                    │     + Filter     │                             │
│                    └─────────┬────────┘                             │
├────────────────────────────────────────────────────────────────────┤
│               Storage (lib/.../storage/)                            │
│     (Storage::Backend protocol; JSON, SQLite implementations)       │
├────────────────────────────────────────────────────────────────────┤
│               Remote cache (lib/.../remote_cache/)                  │
│       (RemoteCache::Backend; S3, LocalFS, Redis adapters)           │
├────────────────────────────────────────────────────────────────────┤
│               Reporters (lib/.../reporters/)                        │
│            (JSON, Terminal, HTML — all optional)                    │
└────────────────────────────────────────────────────────────────────┘
```

Each layer talks to the next only through its public protocol. Layers are
replaceable independently.

## Directory layout (2.0)

```text
rspec-tracer/
├── lib/
│   └── rspec_tracer/
│       ├── version.rb
│       ├── configuration.rb
│       ├── tracker/                  ← core engine
│       │   ├── input.rb
│       │   ├── coverage_adapter.rb
│       │   ├── io_hooks/
│       │   │   ├── file.rb
│       │   │   ├── io.rb
│       │   │   ├── yaml.rb
│       │   │   ├── json.rb
│       │   │   └── kernel.rb
│       │   ├── notifications/
│       │   │   └── action_view.rb
│       │   ├── declared_globs.rb
│       │   ├── whole_suite_invalidators.rb
│       │   ├── dependency_graph.rb
│       │   ├── filter.rb
│       │   └── example_registry.rb
│       ├── storage/
│       │   ├── backend.rb            ← protocol
│       │   ├── json_backend.rb
│       │   ├── sqlite_backend.rb     ← optional
│       │   └── schema_version.rb
│       ├── remote_cache/
│       │   ├── backend.rb            ← protocol
│       │   ├── s3_backend.rb
│       │   ├── local_fs_backend.rb
│       │   └── redis_backend.rb      ← optional
│       ├── reporters/
│       │   ├── base.rb
│       │   ├── json_reporter.rb
│       │   ├── terminal_reporter.rb
│       │   └── html_reporter.rb
│       ├── rspec/
│       │   ├── runner_hook.rb
│       │   ├── reporter_hook.rb
│       │   ├── metadata.rb           ← per-example `tracks:` DSL
│       │   └── parallel_tests.rb
│       ├── rails/
│       │   ├── preset.rb
│       │   └── railtie.rb            ← auto-load when Rails present
│       └── cli.rb
├── spec/
│   ├── spec_helper.rb
│   ├── support/
│   ├── tracker/
│   ├── storage/
│   ├── remote_cache/
│   ├── reporters/
│   ├── rspec/
│   ├── rails/
│   ├── integration/
│   │   └── reference_rails_app_spec.rb
│   └── benchmark/
│       └── cold_boot_spec.rb
├── spec/fixtures/
│   ├── rails_app/                    ← real Rails 7.1 app, load-bearing
│   └── ruby_app/
├── Taskfile.yml                      ← dev loop; see DEV_LOOP.md
├── bin/
│   ├── rspec-tracer                  ← CLI entry
│   ├── actionlint                    ← installed by `task install:tools`
│   └── shellcheck                    ← installed by `task install:tools`
├── benchmark/
│   ├── ratchet.json                  ← committed benchmark thresholds
│   └── harness.rb
├── docs/
│   └── revamp/                       ← this directory
└── ...
```

## Contracts between layers

### Tracker ↔ RSpec integration

```ruby
module RSpecTracer::Tracker
  # Called once at boot, before any examples run.
  def setup(configuration:) ; end

  # Called before each example.
  def start_example(example_id) ; end

  # Called after each example.
  def stop_example(example_id) ; end

  # Returns Set<example_id> to run based on change set.
  def affected_examples(all_example_ids) ; end

  # Called at exit.
  def finalize ; end
end
```

### Tracker ↔ Storage

```ruby
module RSpecTracer::Storage::Backend
  # Returns the stored dependency graph, or nil if none.
  def load_graph(schema_version:) ; end

  # Persists the dependency graph + metadata.
  def save_graph(graph, schema_version:) ; end

  # Atomic: either the whole save succeeds or none of it.
  def transactional_save(&block) ; end
end
```

### Storage ↔ Remote cache

```ruby
module RSpecTracer::RemoteCache::Backend
  # Returns true if a remote cache exists for this ref and was downloaded.
  def download(ref) ; end

  # Uploads the current local cache under this ref.
  def upload(ref) ; end

  # Lists refs available, sorted newest first.
  def list_refs ; end
end
```

## Key data flows

### Cold boot (no cache)

```
start → tracker.setup(config)
      → tracker intercepts all I/O + notifications
      → for each example:
          tracker.start_example(id)
          RSpec runs example
          tracker.stop_example(id)  ← captures inputs
      → tracker.finalize:
          build dependency_graph
          storage.save_graph(graph, schema_version: 2)
          reporters.finalize
```

### Warm run (with cache)

```
start → tracker.setup(config)
      → storage.load_graph(schema_version: 2) → graph
      → change_set = inputs_with_digest_mismatch(graph)
      → if whole_suite_invalidator changed: affected = all examples
        else: affected = graph.examples_depending_on(change_set)
      → tracker intercepts I/O + notifications (still, for this-run data)
      → for each example:
          if affected.include?(id):
            run it, update graph
          else:
            skip, reuse cached outcome + coverage
      → tracker.finalize
```

### Cache corruption recovery

```
start → storage.load_graph → raises or returns nil (corrupted file, bad JSON)
      → log.warn "cache unusable at <path>, falling back to cold run"
      → treat as cold boot
      → finalize writes a fresh cache
```

Never propagate storage errors to the caller.

## Schema versioning

- `schema_version` is an integer field in the root of every cache manifest.
- Current: `1` (legacy 1.x). 2.0 uses `2`.
- Storage backend refuses to load a cache whose `schema_version` doesn't match
  its supported range.
- On version mismatch: log, discard the cache, proceed as cold boot.
- No migrators. Users pay one cold run on upgrade.

## Threading model

- Single-threaded by default. Parallelism is achieved via `parallel_tests` at
  the process level (each process has its own tracker instance, merged at
  end).
- Storage writes happen on a background thread at finalize; the RSpec process
  doesn't block waiting for disk.
- No mutable shared state across threads inside a single tracker instance.

## Extension points

- **Custom storage backend**: implement `Storage::Backend` protocol, register
  via `config.storage_backend MyBackend.new`.
- **Custom remote cache**: implement `RemoteCache::Backend` protocol, register.
- **Custom reporter**: subclass `Reporters::Base`, register.
- **Custom input observer**: subclass `Tracker::Observer`, register in
  config.
- **Per-example input declaration**:
  ```ruby
  describe "foo", tracks: { files: ['app/views/foo/**/*'], env: ['API_KEY'] } do
    # ...
  end
  ```

## Compatibility shims

- `Storage::LegacyJsonBackend` can read 1.x cache files for a one-shot migration
  tool (not part of 2.0 core — a separate `rspec-tracer-migrate` gem if users
  ask for it).
- Default: 1.x caches are ignored, one cold run on upgrade.

## Non-goals for 2.0 architecture

- Language support beyond Ruby (no Python, JS, etc.)
- Language framework support beyond RSpec in this release. Minitest adapter
  possible in a future minor if demand exists.
- Distributed test execution (that's what `knapsack_pro`, `ci-queue`,
  `buildkite-test-splitter` are for; we provide the digest-partition
  primitive but don't schedule).
- Being a general-purpose build tool (we're test-scoped).
