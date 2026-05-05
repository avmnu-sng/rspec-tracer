# Contributing

Thanks for taking the time to contribute. A few pointers so we can
merge your work quickly.

## Reporting issues

- Search first — chances are someone has hit it before.
- Use the bug or feature-request template; fill in every field. The
  [bug template](ISSUE_TEMPLATE/bug_report.md) asks for Ruby / Rails /
  RSpec / SimpleCov versions, your `.rspec-tracer` config, and whether
  the repro still shows up after `task check` — please include them.
- A minimal reproduction (a failing spec, ideally) speeds resolution
  by an order of magnitude.

## Pull requests

### Before you push

- Fork and branch off `main`.
- Work in focused commits; squash noise before opening the PR.
- Add or update tests for every behavioural change.
- Run `task ci` locally and confirm it's green. That's the same
  pipeline CI runs (lint, unit + property + mutation:smoke + dogfood,
  security, benchmark, full-matrix). `task check` is the faster
  feedback loop (lint + unit + benchmark smoke, under ~10 s) for
  inner-loop development.
- Document new public behaviour in the relevant place (README for
  user-facing surface; source-level YARD comments for public APIs).

### When you open the PR

- Fill in the [PR template](PULL_REQUEST_TEMPLATE.md) — it's short.
- Keep the PR to *one* subject. Separate unrelated fixes into
  separate PRs.
- Write a clear title and a description that a reviewer can skim:
  what changed, why, and what testing you did.
- If your change touches performance-sensitive paths, include a
  `task benchmark:full` result summary in the PR body.

## Project conventions

- **Trunk-based.** PRs into `main`. Releases are tags on `main`.
- **Maximum supported surface.** We drop a Ruby / Rails / RSpec
  version only when there's a genuine technical reason (a feature
  we need requires a newer floor, a platform is unshippable). We do
  not drop versions because supporting them is extra work.
- **Graceful degradation.** The tracer must never propagate a failure
  into the user's test suite. Log, degrade, continue.
- **Taskfile is the dev loop.** `task` is the canonical entry point;
  `bundle exec rake` runs only `rubocop` + `rspec` for backward
  compatibility. The Cucumber feature-file suite was retired in
  2.0.0 — RSpec subprocess specs under `spec/integration/` cover the
  same surface.

See `task --list` for the full command catalogue.

## Coverage

Coverage is collected via SimpleCov (line + branch) and uploaded to
Codecov for PR delta + diff-coverage gating (≥ 90% on the patch; no
project drop) and project history. The Codecov UI is the canonical
public surface — see the badge in the README.

Each `task test:*` task sets a unique `COVERAGE_SUITE` env var so
per-suite resultsets land under distinct `command_name`s in
`coverage/.resultset.json` (otherwise each subsequent `bundle exec
rspec` invocation would replace the prior entry — defeating the
multi-suite merge). The SimpleCov configuration lives inline in
`spec/spec_helper.rb` (NOT in a `.simplecov` file at repo root —
SimpleCov's `.simplecov` auto-loader walks upward from `Dir.pwd` and
would leak our config into fixture subprocesses that `chdir` into
`spec/fixtures/rails_app/` or `benchmark/fixtures/ruby_app/`).

Local workflow:

```sh
task coverage:clean              # wipe previous resultsets
task test:unit                   # writes coverage entry under "unit"
task test:edge-cases             # writes entry under "edge-cases"
task coverage:merge -- coverage/.resultset.json   # collated HTML + JSON
open coverage/index.html
```

CI (lint-and-specs.yml): each test job uploads its
`coverage/.resultset.json` as `coverage-test-<job>` artifact; the
`coverage` aggregator job downloads them all, runs `task coverage:merge`,
and pushes the merged JSON to Codecov.

Skip coverage entirely with `COVERAGE=false` (spec_helper guards
SimpleCov.start on `ENV['COVERAGE'] != 'false'`). Mutation runs
auto-skip via `defined?(::Mutant)`.

## YARD comments on public APIs

Add YARD comments to any new public entry point (`RSpecTracer.start`
extensions, new `Configuration#*` DSL methods, new backend protocol
methods, new CLI sub-commands). The .yardopts pinned at the repo
root scopes the public API surface; private helpers don't need
documentation. `task docs:yard` generates the HTML locally.

## Documentation surfaces

- **README** — user-facing concepts, quick start, anything a user
  meets on first install.
- **UPGRADING.md** — every behavior change between major versions
  with a concrete recipe.
- **CHANGELOG.md** — Keep-a-changelog format. Cite commit SHAs /
  version tags / upstream PR numbers. Internal vocabulary
  (working-name milestones, planning IDs) doesn't appear in
  user-facing files.
- **ARCHITECTURE.md** — internals + extension protocols.
- **ROADMAP.md** — phase-level only; the live status lives on the
  GitHub project board.
- **YARD comments** — public API documentation in source.

## Recording demo casts (optional)

The README intentionally ships text-only — selectable, vector,
search-engine-friendly, ages well. If you want to add a terminal
demo cast for a specific feature:

```sh
brew install asciinema
asciinema rec demo.cast --idle-time-limit 2 --cols 100 --rows 28
# inside the recording: clear; bundle exec rspec --no-color; etc.
asciinema upload demo.cast    # prints a https://asciinema.org/a/<id> URL
```

Embed in markdown via the SVG variant:

```markdown
[![asciicast](https://asciinema.org/a/<id>.svg)](https://asciinema.org/a/<id>)
```

The SVG renders inline; click navigates to the playable cast.

## License

By contributing, you agree your code ships under the project's
[MIT license](../LICENSE).
