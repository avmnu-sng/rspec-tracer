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
- **The feedback loop is sacred.** The dev-loop command
  (currently `bundle exec rake`; `task check` after the Taskfile lands)
  must stay fast. Any regression is the highest-priority fix.

## Dev loop

- `bundle exec rake` — full default: rubocop + rspec + feature coverage
  measurements (cucumber). Used by CI's `lint-and-specs` workflow.
- `bundle exec rspec` — unit specs only, fast.
- `bundle exec rubocop` — lint only.
- `bundle exec cucumber --tags "@ruby-app"` — feature subsets.

A Taskfile (`task check`, `task ci`, etc.) is on the roadmap for later
in the 2.0 work.

## Branching and releases

Trunk-based. PRs into `main`. Releases = tags on `main`
(`v1.1.0`, `v2.0.0.pre.1`, ..., `v2.0.0`). A tag push will trigger
`.github/workflows/release.yml` (not yet wired up — planned for the
1.1.0 release cut) which runs the full CI matrix then `gem push` via
`RUBYGEMS_API_KEY`.

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
- Rails: 7.0, 7.1, 7.2 (Rails 8.0 target pending reference-app rework).
- RSpec: 3.12, 3.13.
- Dropped: Ruby ≤ 3.0, Rails ≤ 6.x, RSpec ≤ 3.11, Windows.
- Best-effort (no CI gate): TruffleRuby, Ruby head.
