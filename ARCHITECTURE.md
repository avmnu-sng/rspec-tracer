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
   Concretely: template / partial / collection renders, I18n
   translation loads, and (opt-in, via `track_ar_schema_notifications`)
   ActiveRecord schema-touching queries.
   *Observed via:* `ActiveSupport::Notifications` subscribers plus an
   `I18n::Backend::Base` prepend hook. Cost: already paid by Rails; we
   just listen.

4. **Declared globs** — inputs the user explicitly tells us to track, e.g.
   `config/locales/**/*.yml`, `db/schema.rb`, `Gemfile.lock`. Declared
   through `track_files` / `track_rails_defaults` in config, or
   per-example via the `tracks:` metadata DSL.
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
|-- lib/
|   `-- rspec_tracer/
|       |-- version.rb
|       |-- configuration.rb
|       |-- tracker/                  <- core engine
|       |   |-- input.rb
|       |   |-- coverage_adapter.rb
|       |   |-- io_hooks/
|       |   |   |-- file.rb
|       |   |   |-- io.rb
|       |   |   |-- yaml.rb
|       |   |   |-- json.rb
|       |   |   `-- kernel.rb
|       |   |-- notifications/
|       |   |   `-- action_view.rb
|       |   |-- declared_globs.rb
|       |   |-- whole_suite_invalidators.rb
|       |   |-- dependency_graph.rb
|       |   |-- filter.rb
|       |   `-- example_registry.rb
|       |-- storage/
|       |   |-- backend.rb            <- protocol
|       |   |-- json_backend.rb
|       |   |-- sqlite_backend.rb     <- optional
|       |   `-- schema_version.rb
|       |-- remote_cache/
|       |   |-- backend.rb            <- protocol
|       |   |-- s3_backend.rb
|       |   |-- local_fs_backend.rb
|       |   `-- redis_backend.rb      <- optional
|       |-- reporters/
|       |   |-- base.rb
|       |   |-- json_reporter.rb
|       |   |-- terminal_reporter.rb
|       |   `-- html_reporter.rb
|       |-- rspec/
|       |   |-- runner_hook.rb
|       |   |-- reporter_hook.rb
|       |   |-- metadata.rb           <- per-example `tracks:` DSL
|       |   `-- parallel_tests.rb
|       |-- rails/
|       |   |-- preset.rb
|       |   `-- railtie.rb            <- auto-load when Rails present
|       `-- cli.rb
|-- spec/
|   |-- spec_helper.rb
|   |-- support/
|   |-- tracker/
|   |-- storage/
|   |-- remote_cache/
|   |-- reporters/
|   |-- rspec/
|   |-- rails/
|   |-- integration/
|   |   `-- reference_rails_app_spec.rb
|   `-- benchmark/
|       `-- cold_boot_spec.rb
|-- spec/fixtures/
|   |-- rails_app/                    <- real Rails 7.1 app, load-bearing
|   `-- ruby_app/
|-- Taskfile.yml                      <- dev loop; see DEV_LOOP.md
|-- bin/
|   |-- rspec-tracer                  <- CLI entry
|   |-- actionlint                    <- installed by `task install:tools`
|   `-- shellcheck                    <- installed by `task install:tools`
|-- benchmark/
|   |-- ratchet.json                  <- committed benchmark thresholds
|   `-- harness.rb
|-- docs/
|   |-- CI_RECIPES.md                 <- per-provider CI cache recipes
|   `-- internals/                    <- subsystem deep-dives
`-- ...
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

## Soundness model

"Sound" here means: if a recorded input changes, the tracer is
guaranteed to notice and to re-run every example that recorded it.
Not every input type can carry that guarantee, and this section says
exactly which ones do. The governing rule for everything the tracer
does observe:

> **When a recorded input is ambiguous, the tracer re-runs.** Doubt
> is resolved by running the example, never by skipping it.

The honest cost sits on the other side of that line: an input the
tracer never observed cannot trigger a re-run. The tiers below
classify every input type by which side it falls on. Independent of
tier, examples that previously failed, were flagged flaky, were
pending, or were interrupted are always re-run, as is any example
with no cache entry -- skip decisions apply only to examples with a
clean, fully-recorded history.

### The four tiers

| Tier | Guarantee |
|------|-----------|
| **Sound** | A change to the recorded input is always detected; every example that recorded it re-runs. |
| **Conservative** | Detection is sound, but attribution over-approximates: more examples re-run than strictly necessary, never fewer (within the observed scope). |
| **Heuristic** | Observation rides an event or hook surface that covers the common cases; an input consumed outside that surface is not recorded. |
| **Blind spot** | Not observable at all. Declare it via the escape hatch below, or the tracer cannot see it. |

### Classification by input type

| Input | Mechanism | Tier | Notes |
|-------|-----------|------|-------|
| Whole-suite invalidators (`Gemfile.lock`, `.ruby-version`, `.rspec-tracer`, gem version) | Digest snapshot at boot, value-equality compare | Sound | Any mismatch, including a watched file appearing or disappearing, forces a full run. |
| Project Ruby source (`.rb` under root, not filtered) | `Coverage` diff per example + loaded-files over-approximation | Sound detection, conservative attribution | Content change is always caught (SHA256). Per-example precision degrades to "every example that ran after the file loaded" for files whose use leaves no coverage delta (constant lookups, memoized state). |
| Declared file globs (`track_files`, `tracks: { files: ... }`) | Boot-time walk + digest per run | Sound, given the declaration | The guarantee is conditional and applies to files the cache has seen: any change or deletion under a declared glob re-runs the attributed examples. Files added after the last observed run follow the "New source files" row below. |
| Declared ENV vars (`track_env`, `tracks: { env: ... }`) | Per-run value digest, compared against the cached snapshot | Sound, two documented exceptions | (1) An unset variable and an empty string digest identically, so unset -> `""` is not a change. (2) Wildcard patterns (`RAILS_*`) re-expand against the live environment each run; a variable that disappears entirely also drops off the watch list. Prefer literal names for variables that come and go. |
| Boot-set files (everything loaded before the first example: `spec_helper` requires, gem-loaded engine `lib/`, eager-loaded `app/`) | Digest snapshot of the boot set; any change invalidates the whole suite | Conservative | Deliberately coarse: safe under `config.eager_load = true` and constant autoload timing, at the cost of whole-suite re-runs on boot-file edits. Opt-out: `transitive_load_tracking false` (re-opens the constants-lookup blind spot). |
| New source files | Boot-set snapshot compare + per-run re-walk of declared globs and `lib/**/*.rb` | Conservative when boot-loaded; blind spot when runtime-only | A new file that loads during boot (eager-loaded `app/`, `spec_helper` requires) changes the boot-set snapshot and re-runs the whole suite. A new spec file's examples always run (no cache entry). But a file that is only consumed at runtime (a new locale file, a constant resolved by reflection) cannot appear in any previously-cached dependency set, so by itself it does not re-run previously-passing examples -- it enters the graph on the first run that observes it. |
| File I/O (`File.read`, `YAML.load_file`, `JSON.load_file`, `IO.read`, `Kernel#load`, ...) | `Module#prepend` hooks on class-level entry points | Heuristic | Records exactly what passes through the hooked methods, for allow-listed extensions (`.yml .yaml .json .erb .haml .slim .builder .jbuilder .ru .rake`; `.rb` for `Kernel#load`). Reads via unhooked APIs, C extensions, other extensions, or threads other than the example's are not recorded. |
| Rails template renders | `render_{template,partial,collection}.action_view` subscribers | Heuristic | Attribution is thread-local: renders on another thread (e.g. an app server thread under browser tests) are not attributed. Malformed event payloads are skipped by design. |
| I18n translations | Prepend on `I18n::Backend::Base#load_translations` | Heuristic | Covers backends that super-call `Base` (Simple, Chain, Cascade). A backend that never calls up is invisible; YAML-file backends are also caught by the I/O hook. |
| ActiveRecord schema coupling (opt-in) | First `sql.active_record` event per example attributes `db/schema.rb` + `db/structure.sql` | Heuristic | A proxy, not a parse: any DB-touching example couples to the whole schema file (over-approximate per table), but only if a query event fires on the example's thread during the example. |
| Runtime metaprogramming, monkey-patches in unexecuted or filtered files, ENV branches without declarations, refinements in unexecuted files, database contents | none | Blind spot | See below. |

### What we don't detect

These are the known blind spots -- inputs with no observation
mechanism. If one of them can change an example's outcome, the tracer
will not re-run that example on its own:

- **Runtime metaprogramming.** Behavior manufactured from non-file
  state at runtime (`define_method` / `const_set` driven by data the
  tracer never saw as a file read).
- **Monkey-patches in files that never execute in this process** --
  most commonly gem code outside the project root, or paths excluded
  by a user filter. A patched gem upgrade is still caught, but only
  at `Gemfile.lock` granularity (whole-suite invalidator).
- **ENV-var branches without declarations.** The tracer watches only
  the ENV names that config or example metadata declares.
- **Refinements in unexecuted files.** A `using` whose refinement file
  never loads during the suite leaves no coverage or load trace.
- **Runtime-only new files.** A file added since an example last ran
  and consumed only at runtime cannot be in that example's recorded
  inputs (see the "New source files" row above); boot-loaded
  additions are caught via the boot set.
- **State outside the filesystem.** Database rows, external services,
  the clock: the tracer digests files, not the world. Schema files
  are the closest observable proxy (see the opt-in row above).

The escape hatch for all of these is declaration -- turning an
unobservable input into a declared (sound-tier) one:

```ruby
# .rspec-tracer -- suite-wide
RSpecTracer.configure do
  track_files 'config/feature_flags/**/*.yml'
  track_env 'FEATURE_X'
end

# or per example group, via metadata
RSpec.describe Checkout, tracks: { files: 'db/seeds.rb',
                                   env: 'PAYMENT_GATEWAY' } do
  # ...
end
```

### Reading the tiers as a user

- A **sound** input needs no thought: edit it and the right examples
  re-run.
- A **conservative** input trades precision for safety: expect
  occasional larger-than-necessary re-runs (a boot-file edit re-runs
  everything), never a missed one.
- A **heuristic** input is trustworthy inside its stated surface;
  when your suite consumes it outside that surface (another thread,
  an exotic backend, an unhooked read path), add a declaration.
- A **blind spot** must be declared or accepted. When in doubt about
  whether something is observed, declare it -- a redundant
  declaration costs one digest per run; a missed input costs a stale
  green.

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
