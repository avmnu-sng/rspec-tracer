# RSpec integration

Glue between the v2 engine and RSpec's runner lifecycle. One file per
responsibility.

| File | Role |
|------|------|
| [`installation.rb`](installation.rb) | Prepends `RunnerHook` + `ReporterHook` onto `RSpec::Core::Runner` / `RSpec::Core::Reporter`. Idempotent. Called once from `RSpecTracer.start`. |
| [`runner_hook.rb`](runner_hook.rb) | Overrides `run_specs`. Two-pass filter walk: Pass 1 reads `tracks:` metadata + registers per-example glob/env declarations on the engine; Pass 2 asks `Engine#run_example?` for filter decisions. Mutates `RSpec.world` to the filtered set, logs the `RSpec tracer is running N examples` banner. |
| [`reporter_hook.rb`](reporter_hook.rb) | Overrides `example_started`, `example_finished`, `example_passed`, `example_failed`, `example_pending`. Forwards into `Engine` for dependency attribution; coverage.json emission lives on the dedicated `Reporters::CoverageJsonReporter` finalize path. |
| [`parallel_tests.rb`](parallel_tests.rb) | `TEST_ENV_NUMBER` + `PARALLEL_TEST_GROUPS` detection, `rspec_tracer.lock` lifecycle, narrator selection for log silencing, last-process merge via `Storage::JsonBackend#merge_from_peers`. |
| [`metadata.rb`](metadata.rb) | Per-example `tracks:` DSL walker. Reads `tracks: { files: ..., env: ... }` off an example plus every ancestor group, unions the entries (RSpec's default metadata cascade would clobber on shared keys), and returns the merged `{ files:, env: }` for RunnerHook to register with the engine. |

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

## Per-example metadata DSL

Annotate a describe / context / example with `tracks: { files: ..., env: ... }`
to declare additional dependencies that Coverage + IO observation cannot see:

```ruby
describe 'AdminController',
         tracks: { files: 'app/policies/**/*.rb', env: 'ROLE_CONFIG' } do
  it 'gates on the feature flag' do
    expect(enabled?).to be(true)
  end
end
```

Both keys accept a String glob / env name OR an Array of them. Nested groups
contribute additively — a child group declaring `tracks: { env: 'X' }` does
NOT clobber an ancestor's `tracks: { files: 'Y' }`; both contribute to the
example's dependency set.

Internally: `Metadata.tracks_for(example)` walks `example.example_group
.parent_groups` plus the example itself and returns the union. `RunnerHook`
hands that to `Engine#register_tracks`, which resolves file globs to
`:declared`-kind Inputs and accumulates the env names for the finalize-time
`env_snapshot.json` write. Warm runs compare the previous run's env_snapshot
to the current ENV via `Tracker::EnvSnapshot#invalidated_keys` and mark any
example whose tracked env key drifted as re-runnable
(`EXAMPLE_RUN_REASON[:env_changed] => "Environment changed"`).
