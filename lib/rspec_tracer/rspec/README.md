# RSpec integration

Glue between the v2 engine and RSpec's runner lifecycle. One file per
responsibility.

| File | Role |
|------|------|
| [`installation.rb`](installation.rb) | Prepends `RunnerHook` + `ReporterHook` onto `RSpec::Core::Runner` / `RSpec::Core::Reporter`. Idempotent. Called once from `RSpecTracer.start`. |
| [`runner_hook.rb`](runner_hook.rb) | Overrides `run_specs`. Partitions `RSpec.world.filtered_examples` into tracked + ignored, asks `Engine#run_example?` for filter decisions, mutates `RSpec.world` to the filtered set, logs the `RSpec tracer is running N examples` banner. |
| [`reporter_hook.rb`](reporter_hook.rb) | Overrides `example_started`, `example_finished`, `example_passed`, `example_failed`, `example_pending`. Forwards into `Engine` + `CoverageReporter` so dependency attribution + coverage.json emission stay synchronized. |
| [`parallel_tests.rb`](parallel_tests.rb) | `TEST_ENV_NUMBER` + `PARALLEL_TEST_GROUPS` detection, `rspec_tracer.lock` lifecycle, narrator selection for log silencing, last-process merge via `Storage::JsonBackend#merge_from_peers`. |

## Load-order contract

`RSpecTracer.start` installs the hooks at require time on the classes,
not on an already-constructed Runner instance. Any subsequent
`RSpec::Core::Runner.new` carries `RunnerHook` in its ancestors chain.
This lets `RSpecTracer.start` run before RSpec has constructed its
Runner - the 1.x ObjectSpace-based install required mid-boot timing.

The expected user-facing sequence, unchanged:

```ruby
# spec_helper.rb (no Rails)
require 'simplecov'      # optional
SimpleCov.start           # optional
require 'rspec_tracer'
RSpecTracer.start
# application code loads after this point
```

```ruby
# rails_helper.rb (Rails)
require 'simplecov'
SimpleCov.start
require_relative '../config/environment'
require 'rspec_tracer'
RSpecTracer.start
```

If coverage has already accumulated before `RSpecTracer.start`, the
Installation module logs a warn-level line. Users are still free to
ignore it - the tracer degrades to "attribute whatever we can observe
from now on".

## Per-example metadata DSL (M5.2)

`metadata.rb` is not yet present. It lands with M5.2 to parse
`tracks: { files: '...', env: 'API_KEY' }` metadata and route it into
`Tracker::DeclaredGlobs` per-example attribution.
