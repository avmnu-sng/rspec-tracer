# CLAUDE.md

Guidance for Claude Code (and other AI coding agents) working in this
repository.

## `docs/revamp/` is local-only — never commit it

The `docs/revamp/` tree is the maintainer's internal 2.0 planning material
(milestone briefs, session plans, architecture notes). It is listed in
[`.gitignore`](.gitignore) and must stay there.

- **Do not** `git add docs/revamp/` or any file under it, even if asked
  indirectly ("commit everything", "stage all changes", etc.). Always
  exclude the path explicitly.
- **Do not** copy, paraphrase, or quote content from `docs/revamp/` into
  files that *are* committed (README, CHANGELOG, CLAUDE.md, commit
  messages, PR descriptions).
- When the maintainer directs you to one of those files (e.g. "read
  `docs/revamp/sessions/M1.1-bug-analysis-fixes.md`"), use it as
  conversation context only. The resulting PR must stand on its own
  without any `docs/revamp/` reference.

If the file is missing on a fresh clone, don't re-create it — ask the
maintainer for a local copy.

## Project

`rspec-tracer` — a Ruby gem that speeds up RSpec runs by tracking which
source files each test depends on, so subsequent runs only re-run affected
tests.

A 2.0 revamp is in progress. The authoritative plan lives in the local
`docs/revamp/` tree (see the banner above). This file, the code, and
commit messages are the only materials that survive in the repository.

## Rules of engagement (from the revamp plan)

- **No blind cherry-picks.** Evidence of bugs (issues, fork PRs) is
  *input*; fixes are designed against the current architecture, not
  copied.
- **One session = one PR-sized deliverable.** Don't scope-creep.
- **Every acceptance criterion is mechanically checkable.** If you can't
  check it, rewrite it.
- **Graceful degradation always.** Never propagate a tracer failure into
  the user's test suite.
- **Maximum supported surface.** Drop something only for a genuine
  technical limitation (Windows path semantics, ENV-driven branches with
  no declaration, refinements in unexecuted files). "Effort" is not a
  reason.
- **The feedback loop is sacred.** `task check` (lint + unit specs +
  smoke benchmark) is the dev-loop command; it must stay under ~10 s.
  Any regression is the highest-priority fix.

## Dev loop

- `task check` — the fast feedback loop: `task lint:ruby` + `task test:unit`
  + `task benchmark:smoke`. Runs in ~2 s post-M2.4.
- `task ci` — full CI pipeline locally (lint + check + test + security +
  benchmark + integration).
- `task --list` — full catalog. Common: `task lint:all`, `task test:unit`,
  `task test:features:{ruby,ruby-parallel,rails,jruby}`,
  `task benchmark:{smoke,full,ratchet:update}`,
  `task fixtures:rails:{bundle,migrate,seed,rspec,lint}`,
  `task security:{bundle-audit,trivy}`,
  `task coverage:{merge,clean}`.
- **Coverage**: SimpleCov config lives inline in `spec/spec_helper.rb`
  (NOT in a `.simplecov` file at repo root — SimpleCov's `.simplecov`
  auto-loader walks upward from `Dir.pwd` and would leak our config
  into fixture subprocesses that `chdir` into `spec/fixtures/rails_app/`
  or `benchmark/fixtures/ruby_app/`, causing 3x benchmark regressions).
  Per-suite command_names come from the `COVERAGE_SUITE` env (each
  `task test:*` sets it). Multi-suite resultsets auto-merge into
  `coverage/.resultset.json`; `task coverage:merge` collates them via
  `SimpleCov.collate` and produces `coverage/index.html` +
  `coverage/coverage.json`. CI: `lint-and-specs.yml`'s `coverage` job
  downloads per-job artifacts + uploads to Codecov + uploads merged
  HTML for `docs-publish.yml`. Skip with `COVERAGE=false` env;
  mutation runs auto-skip via `defined?(::Mutant)`.
- `bundle exec rake` is still wired (legacy cucumber path). Removed in
  the 2.0.0 cleanup.

Tool versions are pinned at the top of `Taskfile.yml` (`vars:`); bump
them in one place.

### Prefer `task <name>` over raw `bundle exec …`

The Taskfile is the canonical entry point; each task bakes in the
right env (`RSPEC_TRACER_DISABLE`, paths, flags) and guards (e.g.
mutant Ruby-version check). Reaching past it to `bundle exec rspec …`
bypasses those guards and masks issues that CI will catch. Use direct
`bundle exec` only for targeted debugging (one spec file, one flag) —
always re-run the relevant `task` before committing.

### Pre-PR local parity

`task check` is necessary but **not sufficient** — it only runs
`lint:ruby + test:unit + benchmark:smoke`. Before opening a PR, also
run every task the per-PR CI (`.github/workflows/lint-and-specs.yml`)
runs:

```
task lint:ruby          # already in task check
task lint:actions       # actionlint
task lint:yaml          # yamllint --strict
task check:bundle       # Gemfile.lock installable
task security:bundle-audit
task security:trivy
task test:unit          # already in task check
task test:property      # rantly properties
task test:mutation:smoke # ≥ 90% on TimeFormatter.format_time
task test:dogfood       # tracer-on-tracer subprocess smoke
task benchmark:smoke    # already in task check
```

Why: `task check`'s narrow surface is intentional (10 s budget). The
wider set regularly catches issues `task check` misses — e.g. a new
`spec/support/` gate firing inside `mutant`'s forked test subprocess
or a spec-helper change breaking the dogfood fixture.

### Ruby toolchain

Activate the pinned Ruby (`.ruby-version` → `3.3.10`) via rbenv:

```
export PATH=$HOME/.rbenv/shims:$PATH
```

macOS system Ruby (`/usr/bin/ruby` → 2.6) is too old for this
Gemfile.lock — `bundle exec` without rbenv on PATH fails with
`Could not find 'bundler' (2.6.9)`. Tasks run `ruby:version-check`
as a preconditioned dep, but raw `bundle exec` skips that guard.

## Branching and releases

Trunk-based. PRs into `main`. Releases = tags on `main`
(`v1.1.0`, `v2.0.0.pre.1`, ..., `v2.0.0`). A tag push triggers
`.github/workflows/release.yml`, which validates the tag matches
`RSpecTracer::VERSION`, builds the gem, runs `gem push` via
`RUBYGEMS_API_KEY`, and creates the GitHub release. Shipped as part
of M1.3 / v1.1.0.

## Fork + upstream context

Two Git remotes exist for this codebase:

- **avmnu-sng/rspec-tracer** (upstream; this repo) — the official gem.
- **interviewstreet/rspec-tracer** — HackerRank fork with production
  bug fixes. Merged [PR #1](https://github.com/interviewstreet/rspec-tracer/pull/1)
  (2024) and open PRs [#2](https://github.com/interviewstreet/rspec-tracer/pull/2)
  / [#3](https://github.com/interviewstreet/rspec-tracer/pull/3) (2026).
  SAML-enforced on `gh` CLI; fetch via WebFetch on the GitHub web UI
  when needed.

## CI-gated compatibility

- Ruby: 3.1, 3.2, 3.3, 3.4, 4.0, JRuby 9.4.
- Rails: 7.0, 7.1, 7.2 (Rails 8.0 deferred — see below).
- RSpec: 3.12, 3.13.
- Dropped: Ruby ≤ 3.0, Rails ≤ 6.x, RSpec ≤ 3.11, Windows.
- Best-effort (no CI gate): TruffleRuby, Ruby head.

Full matrix per run is 43 cells (spec × 5 Ruby + ruby-project × 10 +
ruby-parallel × 10 + rails × 15 + jruby + benchmark canary +
lint-and-specs); full definition lives in
`.github/workflows/full-matrix.yml`'s `matrix-config` preflight.

## Phase-2 deferrals worth knowing

Do not re-litigate these in Phase 2 PRs:

- **Rails 8.0 matrix cells** — attempted in M2.3; all 4 cells failed
  because `features/rails_app_*.feature` cucumber scenarios hardcode
  coverage line counts like `"71 / 84 LOC (84.52%)"` that shift under
  Rails 8.0's different initializer load pattern. Re-added when M4.3
  wires the new `spec/fixtures/rails_app/` (Rails-8.0-capable) as the
  CI integration-test target. Full context: M2.3 / M2.4 handoff notes.
- **Benchmark ratchet CI enforcement** — M2.4 ships with
  `--no-enforce` in CI. The committed `benchmark/ratchet.json` was
  generated on Apple M2 Max; GHA `ubuntu-latest` is 1.4-1.6× slower,
  so absolute thresholds would always fail. Followup: regenerate the
  ratchet on GHA and remove `--no-enforce`. Details: M2.4 handoff.
- **`file_read_hook` benchmark scenario** — deferred to M3.2 (1.x
  has no I/O prepend hooks to measure).

Local-only session docs: `docs/revamp/sessions/*.md`. Each `DONE`
session's "Handoff notes" section lists what shipped, deviations from
the brief, and followups. Read the relevant ones before reopening a
milestone's decisions.
