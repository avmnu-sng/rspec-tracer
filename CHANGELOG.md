## [2.0.0.pre.1] - TBD

### Fixed

- **Branch coverage now flows through SimpleCov interop** —
  `Tracker::CoverageAdapter#peek_unfiltered` reduces hash-mode
  Coverage entries to `:lines` only by design (the user-facing
  `coverage.json` shape is documented as `Array<Integer|nil>` per
  file), but that same path was being used by
  `Reporters::CoverageJsonReporter::SimpleCovInterop` to feed
  `Coverage.result` to SimpleCov when rspec-tracer dogfoods itself
  with `enable_coverage :branch` enabled. Result: SimpleCov reported
  branch coverage as `0/0` regardless of how many branches the suite
  actually exercised. Added `peek_unfiltered_full` (preserves the
  `{lines:, branches:}` shape verbatim) and routed the SimpleCov
  interop through it; coverage.json emission still uses
  `peek_unfiltered` so the on-disk shape is byte-identical to 1.x.
  Users with `enable_coverage :branch` now see real branch coverage
  numbers in their SimpleCov reports.

The first pre-release of the 2.0 line. Architecture rewrite around
the input-taxonomy mental model documented in
[`ARCHITECTURE.md`](ARCHITECTURE.md): every test is a pure function
of its inputs; tracking is input identification; cache invalidation
is input-digest mismatch.

The 1.x cache is not readable by 2.0 — first run on the new version
is cold, then warm caches resume. Existing CI integration (`rake
rspec_tracer:remote_cache:download` / `:upload`, the env vars,
the `rspec_tracer_cache/` / `rspec_tracer_coverage/` /
`rspec_tracer_report/` directory contracts) is preserved bit-for-bit.

### Added

- **Pluggable storage backends.** `storage_backend :json` (default,
  preserves 1.x JSON layout) or `storage_backend :sqlite` (single-
  file SQLite database; MRI only — JRuby falls back to `:json` with
  a one-time warn). The 10-file per-run JSON layout (`last_run.json`
  + `<run_id>/{all_examples,duplicate_examples,interrupted_examples,
  flaky_examples,failed_examples,pending_examples,skipped_examples,
  all_files,dependency,examples_coverage}.json`) is unchanged.
- **Pluggable remote-cache backends.** `remote_cache_backend :s3`
  (preserves the 1.x S3 layout including `awslocal` / LocalStack
  support), `:local_fs` (filesystem-backed; no S3 needed), or
  `:redis` (with optional per-key TTL + `<prefix>:pr_branches`
  sidecar SADD on PR-tier uploads for ops dashboards).
- **Per-example `tracks:` DSL.** Annotate any describe / context /
  example with `tracks: { files: 'app/policies/**/*.rb', env:
  'ROLE_CONFIG' }` to declare extra inputs the tracker can't auto-
  observe — config files baked at boot, env-var branches, and
  similar. `:files` accepts a string glob or array; `:env` accepts a
  literal name, array, or single-wildcard pattern (`'RAILS_*'`,
  `'*_TOKEN'`, `'*'`). Cascade unions parent + child without
  clobbering.
- **`track_env(*names)` config-level DSL** for env vars every test
  depends on (`AUTH_TOKEN`, `DATABASE_URL`, `RAILS_ENV`). Same
  wildcard syntax as the per-example `tracks: { env: ... }`.
  Persists as `env_snapshot.json` (concrete keys only, no pattern
  leakage).
- **`track_files(*globs)` config-level DSL** for files every test
  depends on (`Gemfile.lock`, schema, locale catalogs).
- **Rails preset** via `track_rails_defaults` — auto-attaches the
  common Rails-side declared globs (views, locales, fixtures,
  factories, helpers, config). `track_rails_defaults except:
  [:views, :schema]` opts specific globs out so framework-event
  subscribers (`render_template.action_view` for views; the opt-in
  `sql.active_record` observer enabled by
  `track_ar_schema_notifications` for `db/schema.rb`) attribute
  them per-example instead.
- **Auto-detection of Rails** at start time; the engine attaches
  `ActionView` template + `ActiveRecord` schema (when opted in)
  notification observers automatically when `::Rails::VERSION` is
  defined.
- **`bin/rspec-tracer` CLI** with five sub-commands:
  `doctor` (config + environment diagnosis, schema-version + remote-
  cache reachability + AR-schema-narrow checks), `cache:info`
  (size, last run, invalidation stats), `cache:clear` (rm cache
  dirs), `report:open` (open the HTML report in the default
  browser), `explain <example_id>` (show why a given example is
  scheduled to run or skip). The CLI is opt-in for local-dev
  convenience; the `rake rspec_tracer:remote_cache:*` tasks remain
  first-class for CI integration.
- **Boot-time warns** for two common user-trust traps:
  - SimpleCov loaded but not started before `RSpecTracer.start`
    (load-order is part of the documented contract; the warn
    surfaces it instead of silently bolting onto a Coverage already
    in flight).
  - `track_ar_schema_notifications` enabled with
    `use_transactional_fixtures` defaulting to true (per-example
    BEGIN/COMMIT fires `sql.active_record` and attributes
    `db/schema.rb` to every AR-touching example; the warn points
    at the README "Narrow AR-schema attribution" guidance).
- **`.rspec-tracer` DSL typo `did you mean?` suggestions** at config
  load — typos like `track_filez` raise `InvalidUsageError` with a
  pointer at `track_files`.
- **Rails 8.0 CI-gated support** (Ruby 3.2+ required; Rails 8.0
  dropped Ruby 3.1 support upstream). `jruby-9.4 × Rails 8.0` is
  unsupported (no `activerecord-jdbcsqlite3-adapter ~> 80.0`
  upstream).
- **Schema-version field** in `last_run.json` for explicit
  cross-version cache validation. Cache-shape changes bump the
  field; mismatched caches refuse-to-load with an info-level "cold
  run" log line.
- **`docs/CI_RECIPES.md`** translating the
  [`.github/workflows/example-tracer-cache.yml`](.github/workflows/example-tracer-cache.yml)
  GitHub Actions cache pattern to CircleCI / GitLab CI / Buildkite
  / Heroku CI. The 4-component cache key (`runner.os` +
  `.ruby-version` + `lib/rspec_tracer/version.rb` + Gemfile-hash)
  translates 1:1 across providers; only the YAML envelope is
  GHA-specific.
- **Coexistence smokes** for `rspec-retry`, `rspec-rerun`, and
  `knapsack`. All three compose with rspec-tracer's `Module#prepend`
  chain on `RSpec::Core::Runner` / `Reporter` without override.
- **`bin/rspec-tracer doctor` reachability checks** for the
  configured remote-cache backend (S3 / Local-FS / Redis) — surfaces
  misconfigured credentials / missing buckets / unreachable Redis
  hosts at first invocation instead of mid-CI-run.
- **HTML reporter** (committed build output, no `assets:precompile`
  step on user installs) and **JSON reporter** (machine-readable,
  for CI dashboards) alongside the existing terminal output. The
  terminal line now includes a `by reason:` breakdown
  (`12 Files changed · 3 Whole-suite invalidator changed · ...`)
  and a cache size + delta suffix (`14.4 MiB; +6.7 KiB vs prev
  run`).

### Changed

- **Ruby ≥ 3.1** is the floor (1.x supported Ruby 2.5+). 3.2, 3.3,
  3.4, 4.0 + JRuby 9.4 are CI-gated. Rails 7.0 / 7.1 / 7.2 / 8.0 +
  RSpec 3.12 / 3.13 are CI-gated.
- **SimpleCov branch coverage now works alongside rspec-tracer.**
  The 1.x caveat ("SimpleCov would not report branch coverage
  results even when enabled") is **no longer applicable** — the
  coverage-stack rewrite decoupled rspec-tracer's line-only
  emission from SimpleCov's branch-tracking. Users who turned
  `enable_coverage :branch` off when adopting rspec-tracer 1.x can
  re-enable in 2.0.
- **Cache schema bump.** First run on 2.0 is cold; subsequent runs
  return to warm.
- **Coverage adapter** consolidated: a single
  `Reporters::CoverageJsonReporter` owns `coverage.json` emission
  (replacing the 1.x `CoverageReporter` + `CoverageWriter` pair).
  Output shape preserved.
- **Parallel-tests reporter behavior:** terminal / JSON / HTML
  reports now emit ONCE at the merged top-level location after
  `merge_snapshot!` runs, instead of per-worker (where
  `purge_worker_dirs!` then removed them and left users with no
  usable output). Per-worker emission was a pre-2.0 behavior bug.

### Fixed

- **ERB template tracking via `render_template.action_view`** (closes
  the issue behind upstream
  [#66](https://github.com/avmnu-sng/rspec-tracer/issues/66)). The
  Rails subscriber attributes rendered ERB partials to the example
  that triggered the render.
- **Phantom `metadata[:file_path]` graceful skip** (closes the issue
  behind upstream
  [#72](https://github.com/avmnu-sng/rspec-tracer/issues/72)). Specs
  whose `metadata[:file_path]` doesn't resolve to a readable file
  (gem-generated examples, deleted-between-runs files) now log
  debug + skip dependency registration instead of raising.
- **Default filter list now excludes rspec-tracer's own output
  directories** — `rspec_tracer_cache/`, `rspec_tracer_coverage/`,
  `rspec_tracer_report/`, `rspec_tracer.lock`. Previously, tests
  that read the tracer's own cache files (e.g. integration specs
  asserting on cache state after a fixture subprocess run) got
  those paths attributed as deps. The tracer's output is
  regenerated every run by design and should never invalidate a
  test. Both `add_filter` (dep graph) and `add_coverage_filter`
  (coverage report) lists were updated.
- **`add_filter` / `add_coverage_filter` now apply uniformly to
  both fresh attributions AND prior-snapshot carry-forward.**
  Previously, `Engine#seed_all_files_from_previous` and
  `Engine#seed_graph_from_previous` seeded paths from the previous
  run's snapshot WITHOUT re-applying the current filter list — so
  a filter added between runs would NOT exclude already-cached
  paths until a cold run wiped them. Filter additions now take
  effect on the very next warm run.

### Deprecated

The 1.x configuration surface keeps working; each deprecated entry
fires one `logger.warn` at first use pointing at the replacement.
The deprecated values still resolve semantically. All four are slated
for removal in 3.0.

- **`reports_s3_path(uri)`** → use **`remote_cache_uri(uri)`**.
- **`use_local_aws(bool)`** → use **`remote_cache_backend :s3,
  local: true`**.
- **`RSPEC_TRACER_REPORTS_S3_PATH`** → use
  **`RSPEC_TRACER_REMOTE_CACHE_URI`**.
- **`RSPEC_TRACER_USE_LOCAL_AWS`** → fold into
  `remote_cache_backend` params.

### Removed

- **Cucumber feature-file integration suite.** Contributor-facing
  only; users see no change. Replaced by RSpec subprocess
  integration specs under `spec/integration/`. The `bundle exec
  rake` legacy entry point is removed; `task` (Taskfile) is the
  canonical dev loop.
- **Ruby ≤ 3.0 and Rails ≤ 6.x support** (already dropped in 1.1.0;
  re-stated here for clarity at the major boundary).
- **Windows support** (no CI gate; never actively maintained).

### Deferred to 2.1

- **Per-example dependency attribution under Rails
  `config.eager_load = true`.** When `eager_load = true` (Rails
  default for CI tests to mirror prod), all `app/` files load at
  boot and land in the boot-set; the whole-suite invalidator fires
  on any `app/` edit, re-running every example. This is SAFE (never
  misses a dep) but coarser than per-example attribution. The 2.1
  enhancement will install a class-attribution mechanism (working
  name: `track_class_attribution`) using `TracePoint(:class)` at
  boot + `TracePoint(:call)` per example to trim the invalidator
  scope to only examples that touched the changed file's class /
  method surface. Opt-in by default; designed from scratch on the
  user-shape problem (not a resurrection of any 1.x DSL name).
  Today's escape hatches: set `config.eager_load = false` in test
  env for full per-example precision, or use `tracks: { files:
  '...' }` for per-example narrowing on specific groups.

## [1.2.0] - 2026-04-24

### Added

- **`USE_TEST_SUITE_ID_CACHE` env flag** for per-suite remote-cache
  validation. When set to the exact string `"true"`, the validator
  accepts the current `TEST_SUITE_ID`'s cache independently of peer
  suites' state — so an aborted suite on one CI run no longer forces
  a cold run across every suite on the next. Default unset preserves
  1.1.x behaviour byte-for-byte. Ports
  [upstream PR #70](https://github.com/avmnu-sng/rspec-tracer/pull/70)
  (kirpalsangha), with credit to the interviewstreet fork
  ([PR #1](https://github.com/interviewstreet/rspec-tracer/pull/1))
  where the same fix was shipped to HackerRank's production CI in 2024.

### Fixed

- **`SourceFile#file_path` silently dropped dependencies on external
  absolute paths** (closes the issue behind upstream PRs
  [#37](https://github.com/avmnu-sng/rspec-tracer/pull/37) and
  [#67](https://github.com/avmnu-sng/rspec-tracer/pull/67)). When a
  spec's `metadata[:file_path]` resolved to an absolute path **outside**
  `RSpecTracer.root` — typical for shared examples from vendored gems
  (`/opt/bundle/gems/rspec-rails-X/lib/shared_examples/...`) or for
  monorepo spec files adjacent to the project tree — the method stripped
  the leading `/` and expanded against `RSpecTracer.root`, producing a
  non-existent path like `<root>/opt/bundle/...`. `File.file?` returned
  false, `from_path` returned nil, and the tracer **silently skipped
  dependency registration** for that file. Cache-staleness silent-
  correctness bug: shared examples from external gems never appeared as
  dependencies, so changes to them never invalidated the cache. The fix
  returns the input unchanged only when it's an absolute path to an
  existing file outside `RSpecTracer.root`; all other inputs (relative
  paths, stripped-root forms, in-root absolute paths) continue through
  the existing project-relative expansion, preserving byte-for-byte
  behaviour for 1.1.x configurations.
- **`ValidationError` constant now defined.** `remote_cache/validator.rb`
  previously referenced `ValidationError` in its XOR-guard `raise` but
  the constant was never declared anywhere. Tripping the guard
  (setting exactly one of `TEST_SUITE_ID` / `TEST_SUITES`) raised
  `NameError: uninitialized constant` instead of the intended
  error class. Added `class ValidationError < StandardError` inside
  `Validator`, mirroring `Aws::AwsError`.
- **Typo in the XOR-guard error message** — `"enviornment"` →
  `"environment"`.
- **Single-suite `@cached_files_regex` now anchored** — `$` appended
  so the pattern no longer matches extraneous-extension files like
  `/ref/hash/foo.json.backup`. Multi-suite regex was already anchored
  in 1.1.x.
- **`remote_cache/aws.rb#upload_dir` error message** — reported
  `"Failed to download files from …"` when the upload failed. Closes
  upstream [PR #64](https://github.com/avmnu-sng/rspec-tracer/pull/64)
  (C3).

## [1.1.2] - 2026-04-24

### Fixed

- **Encoding crash on locale-unset shells** — legacy cache, report, and
  coverage paths called `File.read` / `File.write` without an explicit
  encoding. Ruby fell back to `Encoding.default_external`, which
  resolves to `US-ASCII` on shells launched without `LANG` set (the
  default for macOS GUI terminals and many LaunchAgent contexts). Any
  spec description containing a non-ASCII byte (e.g. `§`, typographic
  quotes) wrote UTF-8 into `all_examples.json`; the next warm run
  crashed at `Cache#load_*_cache` with
  `Encoding::InvalidByteSequenceError: "\xC2" on US-ASCII`, taking
  `spec_helper` down before any example ran. Every legacy JSON / ERB /
  Ruby-source read and write now pins `encoding: 'UTF-8'`;
  `SourceFile.from_path` switches to `File.binread` so the MD5 digest
  hashes raw bytes regardless of process locale.

## [1.1.1] - 2026-04-23

### Fixed

- **parallel_tests at-exit deadlock** — `parallel_tests_last_process?`
  relied on a lock file written during `RSpecTracer.start` to identify
  the last worker. If a fast worker reached `at_exit` before a slower
  peer had loaded `spec_helper` and registered its `TEST_ENV_NUMBER`,
  both workers could self-elect as the last process, both entered
  `::ParallelTests.wait_for_other_processes_to_finish`, and deadlocked
  on each other's pid. The elector now delegates to
  `::ParallelTests.first_process?`, which reads immutable env vars set
  by the parent at worker spawn. Exactly one worker is elected per run,
  regardless of boot-time ordering or runner CPU count. No public-API
  change — the `rspec_tracer.lock` file is still written and cleaned
  up, just no longer consulted.

## [1.1.0] - 2026-04-20

### Added

- Ruby 3.1, 3.2, 3.3, 3.4, 4.0 are now CI-gated.
- Rails 7.0, 7.1, 7.2 are CI-gated via a reference sample app.
- Regression specs for four crash bugs (B1–B4) under
  `spec/lib/rspec_tracer/`.

### Fixed

- **B1** — `Cache#cached_examples_coverage` returns `{}` (not `nil`)
  when `last_run.json` is present but `examples_coverage.json` is
  missing; previously this leaked nil into the missed-coverage merge.
- **B2** — `Runner#generate_missed_coverage` tolerates a nil cached
  coverage map and nil line-strength entries; both are treated as
  empty / zero.
- **B3** — `Runner#register_{file,example_file}_dependency` skips
  (logs debug, returns false) when `SourceFile.from_path` /
  `.from_name` cannot resolve the file (e.g. gem-generated examples
  or files deleted between runs).
- **B4** — `CoverageReporter#merge_coverage` treats nil existing
  line coverage as 0 when summing skipped-test contributions.
- Custom filter and coverage-filter blocks now reach
  `RSpecTracer::Filter.register` — the DSL wrappers were dropping
  the block, causing `add_filter { |sf| … }` to raise
  `ArgumentError`.
- `load_global_config.rb` wraps `Dir.home` / `Etc.getpwuid.dir` /
  `File.expand_path("~user")` in `rescue ArgumentError` so gem
  load never crashes in minimal containers where HOME is unset and
  the passwd database has no matching entry.

### Changed

- **Behavior change (default filters)** — the default dependency
  and coverage filter lists now exclude Ruby installation /
  toolchain paths: `/lib/rspec_tracer/`, `/lib/rspec_tracer.rb`,
  `/usr/local/lib/ruby/`, `/usr/local/bundle/`,
  `/opt/hostedtoolcache/`, `/.rbenv/versions/`,
  `/.asdf/installs/ruby/`, `/.rvm/`. Previously only
  `/vendor/bundle/` was filtered. A test that previously recorded
  a dependency on a gem file or Ruby stdlib file (because of a
  custom install path like rbenv or asdf) will no longer record
  that dependency — those paths are handled by `Gemfile.lock` /
  the Ruby version file, not by coverage tracking. If you relied
  on the old narrow default, add your own `add_filter` /
  `add_coverage_filter` to clear the extras.

### Removed

- Support for Ruby ≤ 3.0 and Rails ≤ 6.x (EOL).

## [1.0.0] - 2021-10-21

### Added

- [JRuby](https://github.com/jruby/jruby) support
- [Parallel Tests](https://github.com/grosser/parallel_tests) support

### Breaking Changes

The first run on this version will not use any cache on the CI because the number
of files changed from eight to eleven, so there will be no appropriate cache to use.

## [0.9.3] - 2021-10-03

Generate reports ignoring duplicate examples (#42)

## [0.9.2] - 2021-09-30

### Fixed

Caches getting corrupted on interrupts (#39)

## [0.9.1] - 2021-09-23

### Fixed

Flaky and failed examples dependency check (#38)

## [0.9.0] - 2021-09-15

### Added

- Handling all examples filtered by RSpec (#34)
- Warn on incorrect analysis to stop using RSpec Tracer (#35)
- Run `SimpleCov.at_exit` hook (#36)

## [0.8.0] - 2021-09-13

### Fixed

Unable to find cache in case of history rewrites (#33)

## [0.7.0] - 2021-09-10

### Fixed

Missing spec files for the gem

## [0.6.2] - 2021-09-07

### Added

Improvements towards reducing dependency and coverage processing time (#26)

## [0.6.1] - 2021-09-06

### Fixed

Bug in time formatter (#24)

### Added

Environment variable to control verbose output (#25)

## [0.6.0] - 2021-09-05

### Added

- Improved dependency change detection (#18)
- Flaky tests detection (#19)
- Exclude vendor files from analysis (#21)
- Report elapsed time at various stages (#23)

### Note

The first run on this version will not use any cache on the CI because the number
of files changed from eight to nine, so there will be no appropriate cache to use.

## [0.5.0] - 2021-09-03

### Fixed

- Limit number of cached files download (#16)

## [0.4.0] - 2021-09-03

### Added

- Support for CI

## [0.3.0] - 2021-08-30

### Fixed

- `docile` version compatability with `simplecov`

## [0.2.0] - 2021-08-28

### Fixed

- Failures when RSpec required files are outside of project

## [0.1.0] - 2021-08-27

**Initial Release**

### Added

- Ability to run RSpec Tracer with SimpleCov and without SimpleCov
- Support for HTML reports
