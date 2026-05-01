## [1.2.1] - 2026-05-01

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
  spawned. No cache format change.

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
