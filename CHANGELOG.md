## [1.0.5] - 2026-05-17

### Fixed

- **`example_id` is now stable across runs and across no-op edits** —
  `Example.from` previously fed `example.example_group.name` and
  line numbers into the identity-hash payload. Two unrelated effects
  shifted the resulting MD5 across runs that should have been
  identical:

  - `example_group.name` is RSpec's generated class name with a
    load-order-dependent `_2` / `_3` suffix when two spec files share
    a `describe` name (very common — e.g. `describe User do` in
    `user_spec.rb` and `models/user_spec.rb`). The same example got
    a different id depending on rspec's file load order, silently
    thrashing the cache and breaking failed / pending always-re-run
    guarantees.
  - For unnamed examples (`it { }` / `specify { }` / `example { }`),
    `example.description` falls back to RSpec's line-bearing
    `"example at <path>:<line>"` string, so a no-op blank-line edit
    above the example flipped its id and orphaned its cache entry.

  The digest now uses `example_group.description` (the user's
  string, not the generated class name), strips the trailing `:LINE`
  from `shared_group_inclusion_backtrace` entries, and for unnamed
  examples substitutes a line-independent positional discriminator
  (the example's 0-based ordinal among the unnamed examples of its
  group). `line_number` / `rerun_file_name` / `rerun_line_number`
  still ride along in the stored payload for the reporter's location
  columns but no longer enter the digest. Contract: *rename = new
  identity; restructure = same identity.*

  Affected since v1.0.0 (2021). One-time cold run on upgrade: every
  cached `example_id` changes shape, so the first 1.0.5 run misses
  the 1.0.4 cache uniformly and treats every example as no-cache;
  the second run is warm again. Surfaced by the 2.0.0.pre.1 field
  test against third-party Rails apps; ports
  [#209](https://github.com/avmnu-sng/rspec-tracer/pull/209) and
  [#211](https://github.com/avmnu-sng/rspec-tracer/pull/211) onto
  this 1.0.x line. Closes
  [#196](https://github.com/avmnu-sng/rspec-tracer/issues/196) and
  [#210](https://github.com/avmnu-sng/rspec-tracer/issues/210).

- **`RSpecTracer.start` no longer crashes when the user pre-started
  `::Coverage`** — users who want branch coverage typically call
  `Coverage.start(lines: true, branches: true)` before loading the
  tracer. On the previous code path, `setup_coverage` called bare
  `::Coverage.start` unconditionally, which raised
  `RuntimeError: coverage measurement is already setup` and crashed
  the tracer init. `setup_coverage` now guards on `Coverage.running?`
  (Ruby 2.7+) and rescues `RuntimeError` for older Rubies; the
  tracer attaches to the already-running `::Coverage` instance
  instead of raising. Ports
  [#207](https://github.com/avmnu-sng/rspec-tracer/pull/207)'s
  Coverage-guard half (the 2.0-only `coverage_modes` DSL is not
  backported). Closes
  [#195](https://github.com/avmnu-sng/rspec-tracer/issues/195).

- **`remote_cache` download and upload now log on success** — the
  success paths on `RemoteCache::Cache#download` / `#upload` returned
  silently, so a successful `rake rspec_tracer:remote_cache:download`
  produced zero output and users couldn't tell from CI logs whether
  the cache restored. Two `puts` lines now announce success:
  `rspec-tracer remote_cache: restored cache from <sha>` after a
  successful download, and `rspec-tracer remote_cache: uploaded cache
  to <ref>` after a successful upload. Ports the basic-INFO portion of
  [#201](https://github.com/avmnu-sng/rspec-tracer/pull/201) (the
  cross-branch-fallback qualifier and `prune_all!` line are
  2.0-only — 1.x has neither a multi-tier cache nor a prune_all
  path). Closes
  [#188](https://github.com/avmnu-sng/rspec-tracer/issues/188).

### Changed

- **Gemspec now requires MFA for publishing** — adds
  `spec.metadata['rubygems_mfa_required'] = 'true'`. Pure packaging
  metadata; no runtime impact for gem consumers. Ports
  [#214](https://github.com/avmnu-sng/rspec-tracer/pull/214).

## [1.0.4] - 2026-05-06

### Fixed

- **Parallel-tests purge race when a sibling worker is still mid-flush**
  — the elected worker trusted only `parallel_tests`'s pid-file barrier
  (`ParallelTests.wait_for_other_processes_to_finish`), which under
  specific scheduling/I/O timing on GHA Linux x86_64 can return while a
  sibling's `parallel_tests_N/` dir hasn't fully flushed. The elected
  then merged + purged, racing the in-progress sibling. Symptoms:
  intermittent leftover `parallel_tests_N/` dir post-purge AND/OR
  silently dropped peer caches in the merge.

  Backport of upstream PR
  [#168](https://github.com/avmnu-sng/rspec-tracer/pull/168). Adds a
  filesystem barrier layered on top of the pid-file wait. Each worker
  writes a `.rspec_tracer_boot` marker at `RSpecTracer.start` time and
  a `.rspec_tracer_done` marker as the first step of its at_exit tasks;
  the elected worker waits for every booted peer's `.done` to
  materialize before proceeding to merge + purge. Two independent
  signals (pid file + filesystem) must agree before the elected worker
  declares the peer set stable. Bounded at 5 s with a graceful warn
  for crashed peers — their dirs are purged regardless of completion
  state, and the merge accepts whatever's on disk.

## [1.0.3] - 2026-05-04

### Fixed

- **Carry-forward filter contract** — newly-added filters now apply
  uniformly to both fresh attribution AND prior-snapshot carry-forward.
  Previously, `Cache#load_all_files_cache` and `load_dependency_cache`
  read previous-run state without re-applying the current filter list.
  A user adding a new filter mid-development saw the filter take
  effect only for fresh attributions on cold runs; previously-cached
  paths matching the new filter persisted in `all_files` and
  `dependency` until the next cold run. Filter additions now take
  effect on the very next warm run. (from upstream
  [PR #161](https://github.com/avmnu-sng/rspec-tracer/pull/161))

### Note on exclusions

The companion default-filter expansion shipped in upstream PR #161
(adds `rspec_tracer_cache/`, `rspec_tracer_coverage/`,
`rspec_tracer_report/`, `rspec_tracer.lock` to the default
`add_filter` / `add_coverage_filter` lists) is intentionally NOT
backported to this 1.0.x line, for the same reason the broader
1.1.0 default-filter expansion was excluded from 1.0.1: changing
the default filter set shifts the files present in `all_files.json`
for users who track tracer-self paths, which would invalidate their
existing caches on upgrade. Users on 1.0.x who want this default
hygiene can either upgrade to 1.2.x / 2.0.x OR add the four paths
to their own `.rspec-tracer` config explicitly. The carry-forward
filter check shipped here MAKES that user-side `add_filter` take
effect on the next warm run.

## [1.0.2] - 2026-05-01

### Fixed

- **Parallel-tests merge silently dropped peer caches and left worker
  directories behind** when the spawned-worker count exceeded
  `ENV['PARALLEL_TEST_GROUPS']`. The merge + purge call-sites in
  `lib/rspec_tracer.rb` (`merge_parallel_tests_reports`,
  `merge_parallel_tests_coverage_reports`,
  `purge_parallel_tests_reports`) iterated `1..ENV['PARALLEL_TEST_GROUPS']`
  to construct per-worker directory names. But parallel_tests sets
  `PARALLEL_TEST_GROUPS = num_processes.to_s` for each child, where
  `num_processes` is the user-requested process count
  (`Parallel.processor_count` by default) — not the actual worker
  count. When `num_processes < spawned_worker_count` (e.g. when the
  spec-count partition produces more non-empty groups than
  `num_processes`, or shared-runner CPU detection drifts mid-run),
  peer caches with `TEST_ENV_NUMBER` above the env bound were silently
  dropped from the merge (warm-run skip decisions get made against
  an under-sampled merged manifest) and left behind by the purge
  (visible as straggler `parallel_tests_<N>/` directories under
  `rspec_tracer_cache/`). The same gem behaviour was documented on
  v1.1.1's `last_process?` fix
  ([PR #101](https://github.com/avmnu-sng/rspec-tracer/pull/101)) but
  the iteration call-sites kept the buggy bound. Each method now globs
  the actual `parallel_tests_*` subdirectories under its base path,
  making the merge + purge robust to whatever count parallel_tests
  spawned. (from v1.2.1) No cache format change.

## [1.0.1] - 2026-04-24

Long-tail maintenance release. Backports high-impact crash and correctness
fixes from 1.1.x / 1.2.x onto the v1.0.0 foundation so users on Ruby 2.5 -
3.0 who can't upgrade can still pick them up via `gem 'rspec-tracer', '~> 1.0'`.

### Fixed

- `Cache#cached_examples_coverage` returns `{}` (not `nil`) when `last_run.json`
  is present but `examples_coverage.json` is missing, preventing a
  NoMethodError on the next consumer. (B1, from v1.1.0)
- `Runner#generate_missed_coverage` tolerates a nil cached coverage map and
  nil per-line strength entries. (B2, from v1.1.0)
- `Runner#register_file_dependency` / `#register_example_file_dependency`
  skip gracefully when `SourceFile.from_path` / `.from_name` resolves to
  nil (e.g. gem-generated examples whose path is absent at runtime),
  instead of crashing. (B3, from v1.1.0)
- `CoverageReporter#merge_coverage` treats a nil existing line-coverage
  entry as 0 when summing skipped-test contributions. (B4, from v1.1.0)
- `parallel_tests`-mode merge-worker election no longer deadlocks under
  slow CI: the elected worker is now picked via
  `::ParallelTests.first_process?` (immutable at spawn) instead of the
  lock-file max TEST_ENV_NUMBER (racy on slow runners). (from v1.1.1)
- Pin `encoding: 'UTF-8'` on every legacy `File.read` / `File.write` JSON
  I/O site so shells with `LANG=` unset no longer crash the tracer on
  multibyte spec descriptions. Cache (11), report_writer (12), and nine
  other lib/ call sites covered. (from v1.1.2)
- `SourceFile.from_path` computes the file digest via `File.binread`, hashing
  raw bytes regardless of Encoding.default_external. (from v1.1.2)
- `SourceFile.file_path` returns an absolute-external path unchanged when
  the referenced file exists on disk (e.g. shared examples from vendored
  gems at `/opt/bundle/gems/...`), preventing silent drop of dependency
  registration. The guard is narrow — `start_with?('/') &&
  !start_with?(root) && File.file?(path)` — so stripped-root cache forms
  like `/spec/foo.rb` continue through the existing expand_path branch and
  cache `file_name` keys stay byte-identical to v1.0.0. (C1, from v1.2.0)
- `RemoteCache::Aws#upload_dir` error message corrected from
  "Failed to download files from" to "Failed to upload files from". (C3,
  from v1.2.0)
- `RemoteCache::Validator::ValidationError` declared as a proper
  `StandardError` subclass inside `Validator`; previously the
  `TEST_SUITE_ID ^ TEST_SUITES` XOR-guard raised a `NameError:
  uninitialized constant` instead of the intended validation error.
  (from v1.2.0)
- `enviornment` → `environment` typo in the same XOR-guard raise message.
  (from v1.2.0)
- `RemoteCache::Validator`'s single-suite `@cached_files_regex` anchored
  with a trailing `$` so files with extensions beyond `.json` (e.g.
  `.json.backup`) no longer match as cache files. (from v1.2.0)
- `RemoteCache::Repo#initialize` guards `ENV['GIT_BRANCH']` for nil
  before calling `.chomp`; previously a `NoMethodError: undefined
  method 'chomp' for nil:NilClass` crashed the init path and masked
  the intended `RepoError` message when `GIT_BRANCH` was not set in
  the environment. (from v1.1.0 PR #51)
- `RemoteCache::Repo#download_branch_refs` uses `FileUtils.rm_f`
  (not `File.rm_f`) to clean up a partial `branch_refs.json` on a
  failed AWS download. `File.rm_f` is undefined — `rm_f` is a
  FileUtils method — so the failing-download branch would crash with
  `NoMethodError` instead of cleaning up and logging. (from v1.1.0
  PR #65)

### Note on exclusions

The following items from 1.1.x / 1.2.0 are intentionally NOT in this
release to preserve the 1.0.0 cache-format contract and Ruby 2.5+ floor:

- Default-filter expansion (1.1.0 — adds `/lib/rspec_tracer/`,
  `/usr/local/lib/ruby/`, etc. to the default filters). Changing the
  default filter set shifts the files present in `all_files.json` for
  most users, which would invalidate existing caches on upgrade.
- `USE_TEST_SUITE_ID_CACHE` opt-in ENV flag (1.2.0). This is a new
  feature, not a bug fix; users who want it can upgrade to 1.2.x.
- The 1.1+ configuration DSL refactor (anonymous block forwarding,
  alias_method wrapping, ENV.fetch normalizations). These are
  Ruby-3.1-exclusive in places and orthogonal to the crash-fix scope.

### Ruby support

Gemspec `required_ruby_version` unchanged at `>= 2.5.0`. CI gates
Ruby 2.5 - 4.0 inclusive on `ubuntu-latest`.

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
