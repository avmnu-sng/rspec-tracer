# Upgrading

## 1.x → 2.0

The 2.0 line keeps the entire 1.x user-facing surface working: the
configuration DSL, the env vars, the `rake rspec_tracer:remote_cache:*`
tasks, the `.gitignore` directories, the per-run JSON file layout. The
breaking changes are all behind the gem and are documented below with a
concrete "do this, get that" recipe.

The upgrade ceremony for a typical user is two steps:

```sh
bundle update rspec-tracer
bundle exec rspec
```

The first run is cold (the cache schema bumped; 1.x caches are not
read by 2.0). Subsequent runs warm-skip as before.

If you run a custom CI pipeline, jump to **CI integration** below.

## Ruby and Rails floors

| Surface           | 1.x       | 2.0       | Notes                                                                |
|-------------------|-----------|-----------|----------------------------------------------------------------------|
| Ruby (MRI)        | ≥ 2.5     | **≥ 3.1** | 3.2 / 3.3 / 3.4 / 4.0 are CI-gated.                                  |
| Ruby (JRuby)      | 9.2+      | **9.4**   | `JRUBY_OPTS="--debug -X+O"` still required.                          |
| Rails             | 5+        | **7.0+**  | 7.0 / 7.1 / 7.2 / 8.0 are CI-gated. **Rails 8.0 needs Ruby 3.2+.**   |
| RSpec             | ≥ 3.6     | **≥ 3.12**| 3.12 / 3.13 are CI-gated.                                            |
| SimpleCov         | ≥ 0.17    | **≥ 0.22**| Branch coverage now works alongside rspec-tracer (see below).        |
| Windows           | unsupported | unsupported | Never CI-gated.                                                  |

If you need Ruby ≤ 3.0 or Rails ≤ 6.x, stay on the `1.x` line.

## Cache: one cold run on upgrade

The cache is now versioned (`schema_version` field in `last_run.json`).
Loading a 1.x cache with 2.0 logs `cold run: cache schema_version
mismatch (got X, want Y)` at info level and proceeds without it. This is
expected and one-time. Second run on 2.0 returns to warm.

If you upload caches to S3 (or any remote-cache backend), the first
2.0-on-`main` run produces a fresh 2.0-shaped cache that subsequent PR
runs warm-start from. No manual purge needed.

**Rails major upgrades (7.x → 8.0 etc.) also invalidate the cache**
implicitly: `Gemfile.lock` is a whole-suite invalidator, so the lockfile
delta from a Rails major bump triggers a full cold run. Same one-time
expectation applies.

**The 2.0.0.pre.1 → pre.2 upgrade also costs one cold run.** pre.2
reshaped how `example_id` is computed: it no longer depends on RSpec's
load-order-dependent example-group class name or on line numbers, so
cached ids from pre.1 no longer match. The `schema_version` bump makes a
pre.1 cache cold-load cleanly; after that one run, cache hits are *more*
stable than they were under pre.1 — a no-op edit that shifts line
numbers, or loading two spec files that share a `describe` name, no
longer flips an example's identity. As a rule of thumb from pre.2 on:
renaming a file, `describe`, or `it` gives an example a new identity
(one cold run); restructuring around it — blank lines, reordering,
metadata edits — keeps it warm.

One carve-out: an **unnamed** example (`it { ... }`, `specify { ... }`,
`example { ... }` — no description string) has no stable name to hash,
so its identity is its position among the unnamed examples of its
group. Blank-line and comment edits still keep it warm, and adding or
renaming *named* siblings doesn't disturb it — but reordering the
unnamed examples, or inserting/removing one ahead of it, gives the
shifted examples a new identity (one cold run). Give an example an
explicit description for a fully reorder-stable identity.

**The 2.0.0.pre.2 -> 2.0.0.rc.1 upgrade costs no cold run.** The cache
`schema_version` is unchanged (still `5`), so a pre.2 cache carries
forward warm. What rc.1 adds on top is CLI surface, not cache shape:
`bundle exec rspec-tracer blast-radius <file> [<file> ...]` reports how
many examples a change to each file would re-run (`--list` enumerates
them, `--json` for tooling), and `bundle exec rspec-tracer explain
--not-run <example_id>` shows why an example was skipped on the last
run and what would make it run on the next.

## SimpleCov branch coverage now works

The 1.x README warned: *"If you use RSpec Tracer with SimpleCov, then
SimpleCov would not report branch coverage results even when enabled."*

This is **no longer true in 2.0.** rspec-tracer's coverage emission
decoupled from SimpleCov's branch-tracking. If you turned
`enable_coverage :branch` off when adopting rspec-tracer 1.x, you can
re-enable it:

```ruby
SimpleCov.start do
  enable_coverage :branch
end

require 'rspec_tracer'
RSpecTracer.start
```

Load order remains the same — SimpleCov first, then rspec-tracer. If
you call `SimpleCov.start` after `require 'simplecov'` but before
`RSpecTracer.start`, you'll see a one-line boot-time warn pointing this
out.

On the standalone (no-SimpleCov) path, rspec-tracer enables Ruby's
`lines` coverage mode only by default. Opt into branches / methods /
oneshot / eval via `coverage_modes`; see
[`COOKBOOK.md` § "Coverage modes (rspec-tracer + SimpleCov interop)"](COOKBOOK.md)
for the per-mode matrix.

## Deprecated config — keeps working with one warning

Each entry below still functions in 2.0 and warns once at first use.
All four are slated for removal in 3.0.

| 1.x                                  | 2.0 replacement                                       |
|--------------------------------------|-------------------------------------------------------|
| `reports_s3_path 's3://...'`         | `remote_cache_uri 's3://...'`                         |
| `use_local_aws true`                 | `remote_cache_backend :s3, local: true`               |
| `RSPEC_TRACER_REPORTS_S3_PATH=...`   | `RSPEC_TRACER_REMOTE_CACHE_URI=...`                   |
| `RSPEC_TRACER_USE_LOCAL_AWS=true`    | Pass via `remote_cache_backend` params instead.       |

A `.rspec-tracer` file using only the old names runs identically to one
using the new names; the warns are advisory.

## Behavior changes worth knowing

For the full classification of which invalidation decisions are
guaranteed, conservative, or heuristic -- and what the tracer cannot
observe at all -- see the
[soundness model](ARCHITECTURE.md#soundness-model).

### Duplicate example identities

rspec-tracer identifies each example by a hash of its `describe`
chain, description, and file, so it can carry that example's
pass / fail / flaky history across runs. Two examples that hash to
the *same* identity can't be tracked apart — which happens when
examples are genuinely indistinguishable: a copy-pasted `it` with an
identical description in the same group, or a parameterized
`[...].each { it 'same description' do ... end }` loop.

From 2.0.0.pre.2 on, rspec-tracer logs an error that **names the
colliding examples** (file, line, description), **drops just those
examples** from the run, and runs the rest of the suite normally.
`fail_on_duplicates` (default `true`) then governs the exit code —
the run still exits non-zero so the collision can't pass unnoticed in
CI; `fail_on_duplicates false` keeps the exit code at zero. Either
way, the fix is to give the colliding examples distinct descriptions.

Unnamed `it { ... }` blocks do *not* collide this way — each gets a
distinct position-based identity (see the cache section above).

### `track_ar_schema_notifications` precondition

The opt-in `track_ar_schema_notifications` DSL attaches an
`sql.active_record` subscriber that attributes `db/schema.rb` to the
example that touched the database. The narrow promise — "schema edits
re-run only the examples that hit the DB" — only holds when **no
per-example AR cleanup mechanism fires queries inside the rspec-tracer
per-example bucket window**.

The common Rails setups trip this:

- `use_transactional_fixtures = true` (Rails default): per-example
  BEGIN/COMMIT fires `sql.active_record`.
- DatabaseCleaner `:truncation` / `:deletion` / `:transaction` in
  `around` hooks: cleanup queries fire inside the bucket.

In all of the above, every AR-touching example gets `db/schema.rb`
attributed → schema mutations re-run every AR-touching example. **This
is safe** (re-runs more than needed, never fewer) but coarser than the
narrow attribution the DSL implies.

A boot-time warn fires when the precondition is unmet so you don't
discover this from a confused cache-hit-rate chart later. Disable the
warn by either fixing the precondition (set
`use_transactional_fixtures = false` and use sequence-based factories)
or removing the opt-in.

### Per-example precision under `config.eager_load = true`

When Rails CI tests run with `config.eager_load = true` (typical, to
mirror prod), all `app/` files load at boot and land in rspec-tracer's
boot set. Editing any `app/` file then triggers the whole-suite
invalidator and re-runs every example.

This is safe (no false skips) but loses the per-example precision the
new `tracks:` DSL aims for. Two recovery paths:

- **Set `config.eager_load = false` in the test environment** to recover
  full per-example precision.
- **Use the per-example `tracks:` DSL** to narrow attribution on
  specific groups: `RSpec.describe AdminController, tracks: { files:
  'app/policies/**/*.rb' }`.

A future 2.1 enhancement (working name: `track_class_attribution`) will
install class-dispatch tracking to trim the invalidator scope under
eager-loaded test environments. See [`CHANGELOG.md`](CHANGELOG.md)
"Deferred to 2.1" for the planned design contract.

## CI integration

The 1.x flow is preserved bit-for-bit:

```yaml
- run: bundle exec rake rspec_tracer:remote_cache:download
- run: bundle exec rspec
- run: bundle exec rake rspec_tracer:remote_cache:upload
```

Same env vars (`GIT_DEFAULT_BRANCH`, `GIT_BRANCH`, `TEST_SUITES`,
`TEST_SUITE_ID`, `RSPEC_TRACER_REPORTS_S3_PATH` /
`RSPEC_TRACER_REMOTE_CACHE_URI`, AWS credentials).

**Two new things you may want to adopt:**

- **Non-S3 remote caches.** `remote_cache_backend :local_fs, root:
  '/tmp/rspec-tracer-cache'` or `remote_cache_backend :redis, url:
  ENV['REDIS_URL']`. The rake-task surface is unchanged; only the
  storage substrate differs.
- **GitHub Actions native cache** (no S3 needed). See
  [`.github/workflows/example-tracer-cache.yml`](.github/workflows/example-tracer-cache.yml)
  for the canonical pattern. The 4-component cache key
  (`runner.os` + `.ruby-version` + `lib/rspec_tracer/version.rb` +
  Gemfile-hash) translates 1:1 to CircleCI / GitLab CI / Buildkite /
  Heroku CI; only the YAML envelope is GHA-specific. See
  [`docs/CI_RECIPES.md`](docs/CI_RECIPES.md) for the per-provider
  recipes.

## Per-Rails-major coverage golden files (fixture authors only)

If you maintain a Rails-fixture-driven test that asserts byte-equivalence
on `coverage.json` shape, note that **Rails 8.0 loads `config/routes.rb`
AFTER `Coverage.start` fires** (vs 7.x which boots before). The
in-repo fixture ships per-Rails-major goldens
(`spec/fixtures/rails_app/coverage_json.golden` for 7.x +
`coverage_json.golden.rails8`). Resolve which to compare via the
matrix-passed `RAILS_VERSION` env, or use a glob.

Pin `CI=` to the empty string in the subprocess env when the golden
asserts on the eager-load profile, so the fixture's
`config.eager_load = ENV['CI'].present?` resolves to `false`.

## New surfaces worth adopting

These are additive — your existing config keeps working without them.

- **`track_files(*globs)`** — config-level: `track_files
  'config/locales/**/*.yml', 'db/schema.rb', 'Gemfile.lock'`. Files
  every test depends on (the tracker can't auto-observe inputs that
  never showed up in `Coverage.peek_result`).
- **`track_env(*names)`** — config-level: `track_env 'AUTH_TOKEN',
  'DATABASE_URL', 'RAILS_*'`. Wildcards (`PREFIX_*` / `*_SUFFIX` /
  bare `*`) expand against the live ENV at config load.
- **`tracks:` per-example metadata** — `RSpec.describe AdminController,
  tracks: { files: 'app/policies/**/*.rb', env: 'ROLE_CONFIG' }`. Use
  for files / env vars that only a specific group of examples branches
  on (use `track_files` / `track_env` for the global case).
- **`track_rails_defaults`** — Rails preset that opts in to view /
  locale / fixture / factory / helper / config attribution in one DSL
  call. Drop with `track_rails_defaults except: [:views, :schema]` to
  hand attribution off to the per-example subscribers
  (`render_template.action_view` for views; `sql.active_record`
  observer for `db/schema.rb` when paired with
  `track_ar_schema_notifications`).
- **`storage_backend :sqlite`** — single-file SQLite database instead
  of the 10-file JSON layout. Faster on cold reads when you have
  >5,000 examples. JRuby falls back to `:json` automatically.
- **`rspec-tracer` CLI** — opt-in: `bundle exec rspec-tracer doctor`
  diagnoses config issues; `bundle exec rspec-tracer explain <example_id>`
  answers "why did this test (re-)run?" The rake-task flow remains
  first-class for CI.

## Contributor changes

Users see no contributor-side change. If you contribute to rspec-tracer
itself:

- **`bundle exec rake` is gone.** The Cucumber feature-file integration
  suite is removed; RSpec subprocess specs under `spec/integration/`
  replace it. **`task` (Taskfile) is the canonical dev loop.**
  - `task check` — fast loop (lint + unit + benchmark smoke), under ~10s.
  - `task ci` — full local CI parity (lint + check + test + security +
    benchmark + integration).
  - `task --list` — full catalog.
- See [`.github/CONTRIBUTING.md`](.github/CONTRIBUTING.md) for the full
  workflow.

## Where to ask questions

- **Bugs:** open an issue with the bug template; include Ruby / Rails /
  RSpec / SimpleCov versions and your `.rspec-tracer` config.
- **Usage questions / discussion:** [GitHub Discussions](https://github.com/avmnu-sng/rspec-tracer/discussions).
- **Architecture deep-dive:** [`ARCHITECTURE.md`](ARCHITECTURE.md).
