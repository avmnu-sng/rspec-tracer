# rspec-tracer

[![CI](https://github.com/avmnu-sng/rspec-tracer/actions/workflows/lint-and-specs.yml/badge.svg)](https://github.com/avmnu-sng/rspec-tracer/actions/workflows/lint-and-specs.yml)
[![Gem Version](https://badge.fury.io/rb/rspec-tracer.svg)](https://badge.fury.io/rb/rspec-tracer)

**RSpec Tracer** is a specs dependency analyzer, flaky-test detector,
test accelerator, and coverage reporter for RSpec. It records the
inputs every example consumes — Ruby files (via `Coverage`), file
I/O (via prepended `File` / `IO` / `YAML` / `JSON` hooks), Rails
template + AR notifications, and user-declared globs — then re-runs
only the examples whose inputs changed since the last run.

It never skips:
- **Failed**, **flaky**, or **pending** examples.
- Examples whose dependent inputs changed (the whole point).

For a complete account of the input taxonomy and how the engine fits
together, read [`ARCHITECTURE.md`](ARCHITECTURE.md).

## Table of contents

- [Quick start](#quick-start)
- [How it works](#how-it-works)
- [Per-example `tracks:` DSL](#per-example-tracks-dsl)
- [Rails quick start](#rails-quick-start)
- [Configuring CI](#configuring-ci)
- [Remote cache backends](#remote-cache-backends)
- [Pluggable storage](#pluggable-storage)
- [Command-line tools](#command-line-tools)
- [SimpleCov interop](#simplecov-interop)
- [FAQ + comparison](#faq--comparison)
- [Reports](#reports)
- [Help and community](#help-and-community)
- [Section anchor map (1.x → 2.0)](#section-anchor-map-1x--20)

## Quick start

Requires Ruby 3.1+ and rspec-core 3.12+. Rails 7.0+ when using Rails;
Rails 8.0 needs Ruby 3.2+. JRuby 9.4 is supported.

1. Add the gem:

   ```ruby
   gem 'rspec-tracer', '~> 2.0', group: :test, require: false
   ```

2. Add the canonical directories to your `.gitignore`:

   ```
   rspec_tracer.lock
   rspec_tracer_cache/
   rspec_tracer_coverage/
   rspec_tracer_report/
   ```

3. Load and start at the very top of `spec_helper.rb` /
   `rails_helper.rb`, **before any application code:**

   ```ruby
   require 'rspec_tracer'
   RSpecTracer.start
   ```

   With SimpleCov, start SimpleCov first (load order is part of the
   contract):

   ```ruby
   require 'simplecov'
   SimpleCov.start
   require 'rspec_tracer'
   RSpecTracer.start
   ```

4. Run your suite. After the run, open
   `rspec_tracer_report/index.html` for the HTML report, and
   `rspec_tracer_report/report.json` for machine-readable output.

   The terminal prints a one-line summary with cache size and the
   reasons examples re-ran:

   ```
   rspec-tracer: 1,820 examples · 42 re-run · 1,778 skipped (97% cached)
   by reason: 38 Files changed · 4 Failed previously
   cache: rspec_tracer_cache (14.4 MiB; +6.7 KiB vs prev run)
   ```

## How it works

Every test is a pure function of its inputs; the tracker's job is to
identify every input and hash it. Inputs come from six buckets:

1. **Ruby-executed source** — observed via Ruby's `Coverage` module.
2. **File I/O** (`File.read`, `YAML.load_file`, etc.) — observed via
   `Module#prepend` hooks.
3. **Framework events** — Rails template renders + (opt-in) AR
   schema-touching queries via `ActiveSupport::Notifications`.
4. **Declared globs** — what you tell the tracker to track via
   `track_files` / `tracks:` / `track_rails_defaults`.
5. **Whole-suite invalidators** — `Gemfile.lock`, `.ruby-version`,
   `.rspec-tracer`, the rspec-tracer gem version itself.
6. **Truly unobservable inputs** — env-var branches, refinements
   in unexecuted files. Use `track_env` / `tracks: { env: ... }`
   to declare them; the tracker can't auto-detect them.

A digest of every observed input is stored per-example. The next run
loads the cached digest set, recomputes per-input digests, and skips
examples whose inputs are unchanged.

Read [`ARCHITECTURE.md`](ARCHITECTURE.md) for the full layer
structure (Tracker / Storage / RemoteCache / Reporters), data flows,
and extension protocols.

### Per-example precision under Rails `config.eager_load`

A precision tradeoff worth knowing before you run a suite that uses
Rails:

- **`config.eager_load = false`** in test env — per-example precision
  works as designed. Files autoloaded during an example land in
  per-example deps; editing one re-runs only the examples that
  touched it.
- **`config.eager_load = true`** (Rails default for CI tests to
  mirror prod) — all `app/` files load at boot and land in the
  whole-suite invalidator set. Editing any `app/` file re-runs
  every example. **Safe** (never misses a dep) but **coarser** than
  per-example attribution.

If your CI suite runs with `eager_load = true` and your `app/`-edit
cycle is bottlenecked by whole-suite re-runs, set `config.eager_load
= false` in test env to recover per-example precision. A future 2.1
enhancement (working name: `track_class_attribution`) will install
class-dispatch tracking to trim the invalidator scope under
eager-loaded test environments — see
[`CHANGELOG.md`](CHANGELOG.md) "Deferred to 2.1" for the planned
contract.

## Per-example `tracks:` DSL

Annotate any describe / context / example with extra inputs the
tracker can't auto-observe — config files baked at boot, env-var
branches, non-Ruby deps:

```ruby
RSpec.describe AdminController,
               tracks: { files: 'app/policies/**/*.rb',
                         env: 'ROLE_CONFIG' } do
  it 'gates on the feature flag' do
    # ...
  end
end
```

| Key      | Value shape                       | Semantics                                                              |
|----------|-----------------------------------|------------------------------------------------------------------------|
| `:files` | String glob OR Array of strings   | Each matched file is attached as a `:declared`-kind dep on the example. |
| `:env`   | String name OR Array OR wildcard  | Each named env var is digested at finalize. Missing env reads as empty.  |

**Wildcards** (`'RAILS_*'`, `'*_TOKEN'`, `'*'`) expand against the
live ENV at register time; the persisted snapshot only carries
concrete keys.

**Cascade.** Nested groups contribute additively. A parent's
`tracks: { files: 'a/*' }` and a child's `tracks: { env: 'B' }` both
attach to the child's examples; the child does not clobber the parent
on any shared key.

**Use `track_files` / `track_env` for the global case.** Files /
env vars **every** test depends on (`Gemfile.lock`, `AUTH_TOKEN`,
`RAILS_ENV`) belong in `.rspec-tracer`:

```ruby
RSpecTracer.configure do
  track_files 'config/locales/**/*.yml', 'db/schema.rb', 'Gemfile.lock'
  track_env   'AUTH_TOKEN', 'DATABASE_URL', 'RAILS_*'
end
```

## Rails quick start

```ruby
# spec/rails_helper.rb
require 'simplecov'      # if used; load BEFORE rspec_tracer
SimpleCov.start

require 'rspec_tracer'
RSpecTracer.start

require File.expand_path('../config/environment', __dir__)
require 'rspec/rails'
```

```ruby
# .rspec-tracer
RSpecTracer.configure do
  track_rails_defaults
end
```

`track_rails_defaults` attaches the common Rails-side declared globs:
views, locales, fixtures, factories, helpers, config. Drop a
specific glob to hand attribution off to the per-example subscribers
instead:

```ruby
RSpecTracer.configure do
  # Templates → render_template.action_view subscriber attributes
  # them per-example. Schema → opt-in sql.active_record observer
  # attributes db/schema.rb + db/structure.sql per AR-touching
  # example (read the Narrow AR-schema attribution section before
  # enabling).
  track_rails_defaults except: [:views, :schema]
  track_ar_schema_notifications
end
```

Supported Rails matrix: 7.0 / 7.1 / 7.2 / 8.0 (8.0 requires Ruby
3.2+). On JRuby use `JRUBY_OPTS="--debug -X+O"` and the JDBC
adapter (`gem 'activerecord-jdbcsqlite3-adapter', '~> 71.0',
platforms: :jruby` for Rails 7.1; track the major to your Rails
line).

### Narrow AR-schema attribution

`track_ar_schema_notifications` promises per-example attribution of
`db/schema.rb` via the `sql.active_record` subscriber. **The narrow
promise only holds when no per-example AR cleanup mechanism fires
queries inside the per-example bucket.** Common Rails setups trip
this:

- `use_transactional_fixtures = true` (Rails default) — per-example
  BEGIN/COMMIT fires `sql.active_record`.
- DatabaseCleaner `:truncation` / `:deletion` / `:transaction` in
  `around` hooks — cleanup queries fire inside the bucket.

Either case attributes `db/schema.rb` to every AR-touching example
(safe, but widens invalidation). A boot-time warn fires when the
precondition is unmet so you don't discover this from a confused
cache-hit-rate chart later.

For genuinely narrow attribution: set `use_transactional_fixtures =
false` and use sequence-based factories (or another non-AR cleanup
mechanism that doesn't fire `sql.active_record` inside the example
window).

### Working with parallel_tests

Supported out of the box. The tracker writes to per-worker
directories and merges at finalize on the elected last worker. If you
interrupt a run mid-flight, delete the lock file:

```sh
rm -f rspec_tracer.lock && bundle exec parallel_rspec
```

## Configuring CI

The 1.x flow is preserved bit-for-bit. In your project's `Rakefile`:

```ruby
spec = Gem::Specification.find_by_name('rspec-tracer')
load "#{spec.gem_dir}/lib/rspec_tracer/remote_cache/Rakefile"
```

Then in your CI pipeline:

```sh
bundle exec rake rspec_tracer:remote_cache:download
bundle exec rspec
bundle exec rake rspec_tracer:remote_cache:upload
```

With these env vars:

- **`GIT_DEFAULT_BRANCH`** — your repo's default branch (`main` /
  `master`).
- **`GIT_BRANCH`** — the branch the build is on.
- **`TEST_SUITES`** — total number of suite shards (when sharding).
- **`TEST_SUITE_ID`** — current shard identifier.
- **`RSPEC_TRACER_REMOTE_CACHE_URI`** — the remote-cache URI
  (`s3://bucket/prefix`, `file:///tmp/cache`, `redis://host`).

### Caching rspec-tracer in CI

If you don't have S3 — or only need cache between runs of a single
workflow — GitHub Actions' built-in cache is a drop-in storage
substrate. Restore `rspec_tracer_cache/` before specs, run the
suite, let the post-step save it back. A reference workflow lives at
[`.github/workflows/example-tracer-cache.yml`](.github/workflows/example-tracer-cache.yml).
The cache step:

```yaml
- name: Restore rspec-tracer cache
  uses: actions/cache@v5
  with:
    path: rspec_tracer_cache
    key: >-
      ${{ runner.os
      }}-${{ hashFiles('.ruby-version')
      }}-${{ hashFiles('Gemfile.lock')
      }}-rspec-tracer-cache
    restore-keys: |
      ${{ runner.os }}-${{ hashFiles('.ruby-version') }}-
      ${{ runner.os }}-
```

The 4-component cache key (`runner.os` + Ruby version + the
rspec-tracer gem's own version + your project's Gemfile lock)
invalidates when something would make the previous run's decisions
incorrect: native gem binaries differ across runner OSes, Ruby ABI
changes invalidate native extensions, a tracer upgrade can change the
cache schema, and gem-set drift is the most common cache-staleness
trigger.

**The pattern translates 1:1 to CircleCI, GitLab CI, Buildkite, and
Heroku CI**; only the YAML envelope is GHA-specific. See
[`docs/CI_RECIPES.md`](docs/CI_RECIPES.md) for per-provider recipes.

## Remote cache backends

Three backends ship in 2.0. Pick one in `.rspec-tracer`:

```ruby
RSpecTracer.configure do
  # S3 (preserves 1.x layout; supports awslocal / LocalStack).
  remote_cache_backend :s3, local: false

  # Filesystem-backed (no S3 needed).
  # remote_cache_backend :local_fs, root: '/tmp/rspec-tracer-cache'

  # Redis (with optional per-key TTL + PR-branch tracking sidecar).
  # remote_cache_backend :redis, url: ENV['REDIS_URL'], ttl: 7 * 86_400
end
```

The `rake rspec_tracer:remote_cache:*` task surface is unchanged —
backend selection happens in config; the rake tasks dispatch
identically.

## Pluggable storage

Two on-disk storage formats:

```ruby
RSpecTracer.configure do
  # JSON (default) — preserves the 1.x 10-file layout per run.
  storage_backend :json

  # SQLite — single-file database. Faster cold reads above ~5,000
  # examples. JRuby auto-falls-back to :json with a one-time warn.
  # storage_backend :sqlite
end
```

Or override per-run via env: `RSPEC_TRACER_STORAGE=sqlite`.

## Command-line tools

`bin/rspec-tracer` exposes five sub-commands:

```sh
bin/rspec-tracer doctor         # diagnose config + environment
bin/rspec-tracer cache:info     # size, last run, invalidation stats
bin/rspec-tracer cache:clear    # rm cache dirs
bin/rspec-tracer report:open    # open the HTML report
bin/rspec-tracer explain <id>   # why is <example_id> scheduled to (re-)run?
```

The CLI is opt-in for local-dev convenience. The
`rake rspec_tracer:remote_cache:*` tasks remain first-class for CI
integration — nothing in the CLI replaces them.

## SimpleCov interop

**Load order is part of the contract.** SimpleCov first, then
rspec-tracer:

```ruby
require 'simplecov'
SimpleCov.start

require 'rspec_tracer'
RSpecTracer.start
```

If you call `require 'simplecov'` but skip `SimpleCov.start` before
`RSpecTracer.start`, a boot-time warn fires pointing this out
(silent-degradation breaks coverage output).

**Branch coverage works alongside rspec-tracer in 2.0.** The 1.x
caveat ("SimpleCov would not report branch coverage results even
when enabled") is no longer applicable — the coverage emission
decoupled from SimpleCov's branch-tracking. Re-enable
`enable_coverage :branch` in your `SimpleCov.start` block and you get
both.

Filter chains compose: SimpleCov's `add_filter` / `coverage_filters`
control SimpleCov's HTML output; rspec-tracer's `add_filter` /
`add_coverage_filter` control which files contribute to the
dependency graph.

## FAQ + comparison

**Why not just SimpleCov filtering?** SimpleCov tells you which
*files* are covered. rspec-tracer tells you which *examples* depend
on which inputs, so it can skip the ones whose inputs didn't change.
The two solve adjacent problems; you typically want both.

**Knapsack / Knapsack Pro / Test Boosters?** Those are test-splitting
tools — they shard your suite across CI workers. rspec-tracer is
orthogonal: it skips already-passing examples on a single worker.
Compose them: shard with Knapsack, then skip with rspec-tracer.
A composition smoke spec (`spec/regressions/knapsack_coexistence_spec.rb`)
proves they coexist.

**`RSpec::Retry` / `RSpec::Rerun`?** Retries flaky failures.
rspec-tracer detects flaky examples (same inputs, different outcomes)
and refuses to skip them on the next run. Compose: retry to make a
flaky suite green, let rspec-tracer flag the flakes for you to
actually fix.

**Monorepo with N apps?** Set per-app `cache_dir` in each app's
`.rspec-tracer` (the default `rspec_tracer_cache/` would otherwise
collide across apps).

**`tracks:` vs `track_rails_defaults` overlap?** When both attribute
the same file to an example, the declared-glob attribution wins.
Deterministic; see [`ARCHITECTURE.md`](ARCHITECTURE.md) "Input
taxonomy" for the rule.

## Reports

After the run, `rspec_tracer_report/index.html` opens five HTML
reports:

- **All Examples** — basic test info (id, status, duration, the inputs
  the example consumed).
- **Duplicate Examples** — pairs RSpec couldn't uniquely identify
  (file:line collisions; only appears when duplicates are present).
- **Flaky Examples** — examples that passed after previously failing
  without any dependency change. The tracker refuses to skip these
  on subsequent runs.
- **Examples Dependency** — per-example file dependency lists; the
  "what does this test depend on?" view.
- **Files Dependency** — the inverse: "what tests run if I change
  this file?" The unique-to-rspec-tracer report that makes refactors
  safer.

Plus a machine-readable `rspec_tracer_report/report.json` for CI
dashboards and the terminal one-liner shown in [Quick start](#quick-start).

## Help and community

- **Bug reports + feature requests** — [GitHub Issues](https://github.com/avmnu-sng/rspec-tracer/issues).
  Include Ruby / Rails / RSpec / SimpleCov versions and your
  `.rspec-tracer` config.
- **Usage questions, design discussion, "how do I X?"** — [GitHub Discussions](https://github.com/avmnu-sng/rspec-tracer/discussions).
- **Roadmap** — [`ROADMAP.md`](ROADMAP.md) at repo root + the live
  [project board](https://github.com/users/avmnu-sng/projects).
- **Architecture deep-dive** — [`ARCHITECTURE.md`](ARCHITECTURE.md).
- **Upgrading from 1.x** — [`UPGRADING.md`](UPGRADING.md).
- **Contributing** — [`.github/CONTRIBUTING.md`](.github/CONTRIBUTING.md).

Released under the [MIT License](LICENSE). Everyone interacting in
the project is expected to follow the
[Code of Conduct](.github/CODE_OF_CONDUCT.md).

## Section anchor map (1.x → 2.0)

The README was restructured in 2.0. If you bookmarked a 1.x section,
here's where its content lives now:

| 1.x anchor                            | 2.0 anchor                                              |
|---------------------------------------|---------------------------------------------------------|
| `#getting-started`                    | [Quick start](#quick-start)                             |
| `#working-with-jruby`                 | [Quick start](#quick-start) (JRuby noted under floors in [`UPGRADING.md`](UPGRADING.md)) |
| `#working-with-parallel-tests`        | [Working with parallel_tests](#working-with-parallel_tests) under Rails quick start |
| `#configuring-ci`                     | [Configuring CI](#configuring-ci)                       |
| `#caching-rspec-tracer-in-ci`         | [Caching rspec-tracer in CI](#caching-rspec-tracer-in-ci) |
| `#advanced-configuration`             | Split between [Per-example `tracks:` DSL](#per-example-tracks-dsl), [Pluggable storage](#pluggable-storage), and [`UPGRADING.md`](UPGRADING.md) |
| `#available-settings`                 | Inline across the new sections; see also [`ARCHITECTURE.md`](ARCHITECTURE.md) |
| `#filters`                            | Inline under [SimpleCov interop](#simplecov-interop) and the configuration DSL examples |
| `#duplicate-examples`                 | [Reports](#reports) under "Duplicate Examples"          |
| `#demo`                               | [Reports](#reports)                                     |
