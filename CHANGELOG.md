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
