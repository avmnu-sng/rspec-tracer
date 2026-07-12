# rspec-tracer

[![CI](https://github.com/avmnu-sng/rspec-tracer/actions/workflows/ci.yml/badge.svg)](https://github.com/avmnu-sng/rspec-tracer/actions/workflows/ci.yml)
[![Gem Version](https://badge.fury.io/rb/rspec-tracer.svg)](https://badge.fury.io/rb/rspec-tracer)
[![codecov](https://codecov.io/gh/avmnu-sng/rspec-tracer/branch/main/graph/badge.svg)](https://codecov.io/gh/avmnu-sng/rspec-tracer)
[![Docs](https://img.shields.io/badge/docs-online-blue)](https://avmnu-sng.github.io/rspec-tracer/)

**Test-dependency intelligence for RSpec: detect flaky tests, map code
coupling, and -- when you are ready -- re-run only what changed.**

rspec-tracer records the inputs it can observe for each RSpec
example -- Ruby files, file I/O, Rails templates and queries,
declared globs and ENV branches -- and turns that record into a
flaky-test detector, a per-example dependency map, and optional CI
acceleration. The flaky report and the dependency map never skip a
test: value before trust.

**Measured, not promised.** In the maintainer's May 2026 field test
(rspec-tracer 2.0.0.pre.1, Apple M2 Max), Mastodon's `spec/lib` --
1,234 examples, Rails 8.1.3, Ruby 3.4.8 -- ran in 116.4 s cold and
17.0 s warm: **6.85x**, with the tracer's own recording overhead
included in both runs. "Cold" here is the tracer's own first run,
not plain RSpec: recording costs roughly 1.6x plain RSpec on this
repository's Rails benchmark fixture (approximate), and no
tracer-free Mastodon baseline was measured, so your gain over a
suite without the tracer will be smaller than cold minus warm.
Suite shape matters: across the same field tests, warm-run skip
rates ranged from 31% (a suite carrying 177 pre-existing failures --
failed examples are never skipped) to 100%. Measure your own suite
before you rely on these numbers.

**Conservative by design, honest about its limits.** The tracer
never skips failed, flaky, or pending examples, nor any example
whose recorded inputs changed; when a recorded input is ambiguous,
it re-runs. Real blind spots exist -- runtime metaprogramming and
monkey-patches are invisible to it; the `tracks:` DSL is the escape
hatch -- and the [soundness model](ARCHITECTURE.md#soundness-model)
catalogues the known blind spots. Shadow mode (run everything,
report what would have been skipped) lands in v2.0.0.rc.2, so you
can verify the tracer on your own data before trusting it with a
single skip.

**Your data never leaves your infrastructure.** Everything runs inside
your test process and your CI cache -- no SaaS backend, no telemetry,
no per-seat pricing.

## Quick start

Requires Ruby 3.1+ and rspec-core 3.12+ (Rails 7.0+ when using Rails;
Rails 8.0 needs Ruby 3.2+; JRuby 9.4 supported). Every CI-gated Ruby
is supported until at least six months past its upstream EOL -- see
[Maintenance](#maintenance).

```ruby
# Gemfile -- 2.0 is in pre-release; pin explicitly until 2.0.0 final
gem 'rspec-tracer', '= 2.0.0.pre.2', group: :test, require: false
```

Add the tracer's working directories to your `.gitignore` before the
first run:

```
rspec_tracer.lock
rspec_tracer_cache/
rspec_tracer_coverage/
rspec_tracer_report/
```

```ruby
# Top of spec_helper.rb / rails_helper.rb, before any application
# code. With SimpleCov, start SimpleCov first -- load order is part
# of the contract.
require 'rspec_tracer'
RSpecTracer.start
```

Run the suite twice. The second run skips the examples whose recorded
inputs are unchanged and prints a per-reason breakdown of what
re-ran; open `rspec_tracer_report/index.html` to audit every
per-example decision. Not ready to let it skip anything? Set
`RSPEC_TRACER_RUN_ALL_EXAMPLES=true` (or `run_all_examples true`
inside the `RSpecTracer.configure` block in `.rspec-tracer`) --
every example still runs while the flaky report and the dependency
maps accumulate data.

Setting up CI? [docs/CI_RECIPES.md](docs/CI_RECIPES.md) has
copy-paste cache recipes for CircleCI, GitLab CI, Buildkite, and
Heroku CI, plus a link to the canonical GitHub Actions workflow.

## Table of contents

- [Quick start](#quick-start)
- [What it saves](#what-it-saves)
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
- [Maintenance](#maintenance)
- [Documentation + coverage](#documentation--coverage)
- [Help and community](#help-and-community)
- [Section anchor map (1.x -> 2.0)](#section-anchor-map-1x--20)

## What it saves

All timings are wall-clock and measured, not projected: maintainer
field tests, May 2026, Apple M2 Max, rspec-tracer 2.0.0.pre.1. In
every row, "cold" is the tracer's own first, recording run -- it
costs more than plain RSpec (roughly 1.6x on this repository's Rails
benchmark fixture; approximate), and no tracer-free baseline was
measured for these projects -- so your savings versus a suite
without the tracer will be smaller than cold minus warm.

| Project measured | Examples | Cold run | Warm run | Warm skip rate | Saved per warm run |
|---|---|---|---|---|---|
| Mastodon `spec/lib` (Rails 8.1.3, Ruby 3.4.8) | 1,234 | 116.4 s | 17.0 s | 98% (1,212 skipped) | ~99 s |
| thoughtbot/clearance (Rails 8 engine + dummy app) | 258 | 11.1 s | 1.6 s | 100% | ~9.5 s |
| publify (carries 177 pre-existing failures; failed examples are never skipped) | 257 | 6.7 s | 4.8 s | 31% | ~1.9 s |

The Mastodon warm run is the zero-change best case; in the same
field test, editing one file re-ran 68 of 1,234 examples in 19.0 s.
Laptop rows understate CI savings: CI runners are slower than the
development machine, so the seconds saved per run are typically
larger there -- the skip ratios are what transfer.

**Worked examples** (every input is an assumption you should replace
with your own). For any suite:

`(cold seconds - warm seconds) x runs/day / 60 x $/CI-minute x 30 = $/month per full-suite job`

At $0.006/CI-minute (illustrative -- GitHub-hosted Linux list price
at the time of writing; check your provider's current rate) and 50
CI runs/day on one job:

- Best case (a Mastodon-sized suite saving ~99 s per warm run):
  ~83 CI-minutes/day, about $15/month per job.
- Low-skip case (a publify-shaped suite saving ~1.9 s per warm run
  at 31% skip): about $0.29/month per job.

Multiply by the number of jobs that each run the full suite (for
example, a Ruby-version matrix); jobs that split one suite across
workers share the saving rather than multiply it.

Conservative assumptions: 50 runs/day and the dollar rate are stated
assumptions, not measurements; your skip rate may be far lower (see
the 31% row -- suites with many failing examples skip less, by
design); remote-cache download time on fresh CI workers is not
subtracted (measured end-to-end remote-cache gain on clearance was
still ~4.6x).

## How it works

Each example's observed inputs -- executed Ruby source (via
`Coverage`), file I/O (via `Module#prepend` hooks), Rails framework
events, declared globs and env vars, and whole-suite invalidators
like `Gemfile.lock` -- are digested and stored per example. The next
run recomputes the digests and skips examples whose recorded inputs
are unchanged. The full input taxonomy lives in
[ARCHITECTURE.md](ARCHITECTURE.md#input-taxonomy); what each input
kind does and does not guarantee is the
[soundness model](ARCHITECTURE.md#soundness-model); the Rails
`config.eager_load` precision trade-off is covered by the Rails
recipe in [COOKBOOK.md](COOKBOOK.md).

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

Copy-paste cache recipes for CircleCI, GitLab CI, Buildkite, and
Heroku CI live in [docs/CI_RECIPES.md](docs/CI_RECIPES.md); the
canonical GitHub Actions workflow is
[`.github/workflows/example-tracer-cache.yml`](.github/workflows/example-tracer-cache.yml).
The rest of this section covers the remote-cache rake flow and the
cache-key pattern all the recipes share.

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

The 4-component cache key (`runner.os` + Ruby version + your
project's Gemfile lock -- which also pins the rspec-tracer gem's
version -- + a fixed name suffix) invalidates when something would
make the previous run's decisions incorrect: native gem binaries
differ across runner OSes, Ruby ABI
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

`rspec-tracer` exposes five sub-commands. Run them via Bundler so the
gem's executable resolves cleanly without needing `bundle binstubs
rspec-tracer` first:

```sh
bundle exec rspec-tracer doctor         # diagnose config + environment
bundle exec rspec-tracer cache:info     # size, last run, invalidation stats
bundle exec rspec-tracer cache:clear    # rm cache dirs
bundle exec rspec-tracer report:open    # open the HTML report
bundle exec rspec-tracer explain <id>   # why is <example_id> scheduled to (re-)run?
```

Generated binstubs (`bin/rspec-tracer …`) work too once you've run
`bundle binstubs rspec-tracer` in your project. The CLI is opt-in for
local-dev convenience; the `rake rspec_tracer:remote_cache:*` tasks
remain first-class for CI integration — nothing in the CLI replaces
them.

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

**Datadog Test Optimization / Buildkite Test Analytics / CircleCI
Test Insights?** Those are hosted services: your test metadata ships
to a vendor backend, with the pricing and procurement that implies.
rspec-tracer runs entirely inside your test process -- the cache and
reports are plain files in your repo, S3 bucket, or Redis. No SaaS
backend, no telemetry, no per-seat pricing; keeping it that way is a
standing commitment in [ROADMAP.md](ROADMAP.md)'s "Won't do" list.

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
reports. The first two deliver value even if you never let the
tracer skip a single example:

- **Flaky Examples** -- examples that failed on one run and passed on
  a later one, the canonical intermittence signal: a flake list your
  suite builds passively from the runs you were already doing. Once
  flagged, the tracer refuses to skip them on subsequent runs.
- **Files Dependency** -- "if I change this file, which tests run?"
  The file-to-test map that makes refactors, reviews, and deletions
  safer -- the report unique to rspec-tracer.
- **Examples Dependency** -- the per-example inverse: "what does this
  test depend on?"
- **All Examples** -- basic test info (id, status, duration, the
  inputs the example consumed).
- **Duplicate Examples** -- pairs RSpec couldn't uniquely identify
  (file:line collisions; only appears when duplicates are present).

Plus a machine-readable `rspec_tracer_report/report.json` for CI
dashboards, and a terminal summary with a per-reason breakdown after
every run (see [Quick start](#quick-start)).

## Maintenance

Every CI-gated Ruby is supported until **at least** six months past
its upstream end-of-life date. That is a floor, not a drop date:
versions can stay supported longer, and Ruby 3.1 currently is.
Upstream EOL dates are published on the official
[Ruby maintenance schedule](https://www.ruby-lang.org/en/downloads/branches/);
that page is authoritative for the dates below.

| Version | CI-gated | Status |
|---------|----------|--------|
| Ruby 3.1 | Yes | Supported. Upstream EOL was 2025-03-26, so the committed six-month window has lapsed -- and 3.1 is still supported today because the policy is a minimum, not a schedule. It remains the floor for the 2.0 release line. |
| Ruby 3.2 | Yes | Supported. Upstream EOL was 2026-04-01; supported until at least 2026-10-01, and potentially longer -- the policy is a minimum. |
| Ruby 3.3 | Yes | Supported. Upstream EOL is expected 2027-03-31; supported until at least six months past the published EOL date. |
| Ruby 3.4 | Yes | Supported, until at least six months past its upstream EOL date (not yet announced). |
| Ruby 4.0 | Yes | Supported, until at least six months past its upstream EOL date (not yet announced). |
| JRuby 9.4 | Yes | Supported. JRuby support tracks the JRuby project's own maintenance schedule, not the Ruby-Core EOL dates above. |

TruffleRuby and Ruby head are best-effort: no CI gate, but issue
reports are welcome and get investigated.

## Documentation + coverage

- **Docs site**: [avmnu-sng.github.io/rspec-tracer](https://avmnu-sng.github.io/rspec-tracer/)
  publishes a YARD API reference, the cookbook, internals deep-dives,
  and the sample HTML report for every rolling main + tagged release.
  The landing page lets you switch versions; per-version subpaths look
  like `/main/yard/`, `/main/demo/`, `/v2.0.0.pre.1/yard/`, etc.

- **Coverage**: tracked by [Codecov](https://codecov.io/gh/avmnu-sng/rspec-tracer)
  (per-PR delta + diff-coverage gate ≥ 90%; project history). Multi-
  suite resultsets (`unit`, `edge-cases`, `regressions-plain`, `fuzz`)
  merge via SimpleCov.collate in the CI `coverage` job; the same
  merger runs locally via `task coverage:merge` after `task test:*`
  runs (open `coverage/index.html` for the local HTML report).

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
