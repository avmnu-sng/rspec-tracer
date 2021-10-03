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
