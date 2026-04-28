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

Platform gate: effectively MRI ≥ 3.3 (mutant 0.16's README says 3.2+,
but its transitive dep `unparser 0.9.0` declares `required_ruby_version
>= 3.3`, so 3.2 bundle installs fail). Ruby 3.1 / 3.2 / JRuby cells
skip the gem via `Gemfile`'s `install_if`; `task test:mutation:*`
skips quietly on those platforms rather than erroring out.

### Running

    task test:mutation:smoke   # 13 subjects, all must hit >= 90% (~2 min)
    task test:mutation:full    # smoke + 7 per-module subtasks (parallel CI)

### Per-module subtasks

The full mutation pass is split across 7 per-module Taskfile subtasks
that each cover a `lib/rspec_tracer/<subdir>/` lane. Each subtask
carries per-subject carve-out gates with inline rationale comments;
inspect the Taskfile when investigating a subject's gate value.

| Subtask                             | Subdir                              |
|-------------------------------------|-------------------------------------|
| `task test:mutation:tracker`        | `lib/rspec_tracer/tracker/`         |
| `task test:mutation:storage`        | `lib/rspec_tracer/storage/`         |
| `task test:mutation:rspec`          | `lib/rspec_tracer/rspec/`           |
| `task test:mutation:top-level`      | `lib/rspec_tracer.rb`               |
| `task test:mutation:remote-cache`   | `lib/rspec_tracer/remote_cache/`    |
| `task test:mutation:rails`          | `lib/rspec_tracer/rails/`           |
| `task test:mutation:reporters`      | `lib/rspec_tracer/reporters/`       |

CI runs them as parallel jobs in
[`.github/workflows/lint-and-specs.yml`](../.github/workflows/lint-and-specs.yml)
on every PR + every push to main. The `lint-and-specs` consolidator
job is the single required-status-check that branch protection gates
on; it succeeds iff every parallel job below it succeeded.

### Interaction with the tracer

`spec/spec_helper.rb` skips `RSpecTracer.start` when
`RSPEC_TRACER_DISABLE=1` is set in the environment. Mutant tasks set
that flag automatically. Reason: the tracer's own `start` path calls
`TimeFormatter.format_time`; a mutation that makes that raise would
crash spec-helper setup before any test could run, which mutant would
misreport as "survived".

### When you see a surviving mutation

`mutant` reports "Alive" when no test in the selected set fails on a
mutated source variant. That signal has six common causes. Diagnose in
this order before suspecting weak tests, then act per the matching
branch:

**1. Spec-helper crash mistaken for "alive".** Mutant cannot distinguish
"0 tests failed" from "0 tests ran." If the mutation makes spec-helper
setup raise, every test in the suite is skipped and mutant reports
100% alive. Fix: set `RSPEC_TRACER_DISABLE=1` in the Taskfile env
block (every per-module subtask already does); confirm the spec_helper
honors the flag. See `feedback_mutant_rspec_gotchas` (memory).

**2. Subject undefined / `Subjects: 0` in the mutant summary.** Causes:
the source file uses `module_function` (the singleton + private-instance
duplication makes mutant mutate the unreachable instance method - see
`feedback_mutation_friendly_modules`); or the subject is defined inside
a `Struct.new do ... end` block (mutant rejects - reopen the class via
`class X < Struct.new(...)`); or non-ASCII bytes in lib/ source crash
mutant's US-ASCII parser (see `feedback_mutant_non_ascii_source`).
Action: refactor lib to `def self.x`, reopen Struct subclasses, ASCII-
clean comments + string literals.

**3. Equivalent guard, rescue downstream.** Mutation strips a
`return nil unless File.file?(path)` (or similar) but the method's
trailing `rescue StandardError` swallows the same `Errno::ENOENT` the
guard was preventing. The mutation IS observably equivalent. Action:
DROP the guard via lib refactor (with the maintainer-articulated
"guarantee on behavior + perf intact" bar). Code clarity drives the
refactor; coverage is a side effect. Precedents: M3.3
`WholeSuiteInvalidators#file_digest`, M8.3-B `RemoteCache::Validator`.
See `feedback_mutant_equivalent_guards`.

**4. Mutant first-token describe-mapping ceiling.** Mutant maps tests to
subjects via the first space-separated token of `full_description`.
A method whose behavior is exercised under a *sibling* method's describe
(e.g. `#initialize` walker setup tested through `describe '#new_files'`,
or private helpers reached via the public method's describe block) gets
zero credit even though the behavior IS exercised end-to-end. Combined
describes like `'.install / .installed? / .uninstall'` credit only the
first method (`.install`). Prose-form describes (`'fallback rendering'`,
`'graceful degradation'`, `'envelope'`, `'BUILT_INS constant'`,
`'bucket lifecycle'`) don't match any `Klass#method` / `Klass.method`
pattern at all. Action: ACCEPT VIA CARVE-OUT - size the gate value to
include the alive-but-functionally-tested mutations and document the
ceiling in an inline Taskfile rationale comment. Do NOT restructure
describes for coverage - that's the test-organization-for-coverage
anti-pattern. Restructure ONLY when a describe label honestly belongs
under a different method. See `feedback_mutant_describe_label_ceiling`.

**5. `Module#prepend` idempotency.** Ruby has no `unprepend` API. Once
any prior test triggers `Klass.prepend(Hook)`, subsequent installs
(mutated or not) leave the singleton-class ancestor chain unchanged,
so prepend-line mutations stay alive in shared-process spec suites.
rspec-mocks spies don't help (singleton-class inheritance routes the
spy to the wrong target). Subprocess isolation closes the gap but
blows up wall-clock budget. Action: ACCEPT VIA CARVE-OUT with
inline rationale comment referencing the memory. Do NOT add
prepend-spy tests - they verify nothing real. Precedents:
`Tracker::IOHooks` (M8.3-A), `Rails::I18nTracking::LoadTranslationsHook`
(M8.3-C). See `feedback_mutant_prepend_idempotency`.

**6. Local-vs-CI variance ≥ 5 pp.** Same source + same mutant version
+ same gem set produces materially different alive counts between local
M2 Max and CI ubuntu-latest because of test-ordering shifts (no
Gemfile.lock per M3.8 Part C), parallelism differences (mutant
`Jobs: 12` on M2 Max vs `Jobs: 4` on CI), and state-leaking
memoizations (e.g. `@msgpack_loaded` ivar hiding `require 'msgpack'`
mutations once any prior test trips the memo). Action: SIZE GATES from
CI numbers + ~3-5 pp margin under, NEVER local. Re-cut the gate
downward in a follow-up commit if any subject drops materially below
local on the first CI run. Precedents: M8.3-A `154ec27`, M8.3-B
`10c0d67`. See `feedback_mutant_local_vs_ci_variance`.

**Genuine gap, not a ceiling?** Add a behavior test under the natural
describe that asserts the real contract being broken by the mutation.
Never weaken an existing assertion to make CI green
(`feedback_never_weaken_tests`). Never add mutation-bait tests that
exist only to kill mutations - the test should document a real
contract the lib promises. If the contract is fuzzy (e.g. log-message
wording), `# mutant:disable - <one-line rationale>` with a
maintainer-reviewed comment is acceptable; carve-out gates are
preferred over per-method disables because they surface the gap
rather than silencing it.
