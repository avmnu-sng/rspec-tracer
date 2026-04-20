# `spec/` — test suite layout

The test layers that ship in this tree today:

| Path                          | Framework                | How to run                    |
|-------------------------------|--------------------------|-------------------------------|
| `spec/**/*_spec.rb` (root)    | RSpec 3.13               | `task test:unit`              |
| [`spec/properties/`](properties/) | rantly + rspec_extensions | `task test:property`      |
| [`spec/fuzz/`](fuzz/)         | Hand-rolled script       | `task test:fuzz:smoke` / `:full` |
| `spec/integration/`           | RSpec subprocess shell   | `task test:dogfood`           |

Each of `properties/`, `fuzz/`, and `integration/` has its own README
with framework-specific guidance.

## Mutation testing

Framework: [mutant](https://github.com/mbj/mutant) via the `mutant-rspec`
integration. Licensing: `--usage opensource` — no license key needed for
public repositories.

Platform gate: mutant 0.16 requires MRI ≥ 3.2, which means Ruby 3.1 and
JRuby matrix cells can't install the gem. `Gemfile`'s `install_if` keeps
the gem out of incompatible environments; `task test:mutation:*` skips
quietly on those platforms rather than erroring out.

### Running

    task test:mutation:smoke   # TimeFormatter.format_time, must hit >= 90%
    task test:mutation:full    # whole TimeFormatter module, informational

### Scope today

Smoke targets `RSpecTracer::TimeFormatter.format_time` only. That method
was refactored from `module_function` to `def self.format_time` so the
mutation engine can actually reach the code path tests call — see
[`time_formatter.rb`](../lib/rspec_tracer/time_formatter.rb). Mutation
coverage on the remaining private helpers (`format_duration`,
`strip_trailing_zeroes`, `pluralize`) and on other modules is the job
of M8.3 ("mutation testing pass").

### Interaction with the tracer

`spec/spec_helper.rb` skips `RSpecTracer.start` when
`RSPEC_TRACER_DISABLE=1` is set in the environment. Mutant tasks set
that flag automatically. Reason: the tracer's own `start` path calls
`TimeFormatter.format_time`; a mutation that makes that raise would
crash spec-helper setup before any test could run, which mutant would
misreport as "survived".
