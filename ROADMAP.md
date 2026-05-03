# Roadmap

This is the public roadmap for rspec-tracer. The **live status** of
specific work items lives on the project board:
[github.com/users/avmnu-sng/projects](https://github.com/users/avmnu-sng/projects).

This file summarizes phases at a high level — what shipped, what's
next, what's being considered. Detail per item lives in
[`CHANGELOG.md`](CHANGELOG.md), the project board, and the linked
issues / PRs.

---

## 2.0 — shipped

The 2.0 line is a ground-up architecture rewrite around the
input-taxonomy mental model: every test is a pure function of its
inputs; tracking is input identification; cache invalidation is
input-digest mismatch. The full feature list is in
[`CHANGELOG.md`](CHANGELOG.md). The headline themes:

- **Pluggable storage** — JSON (default; preserves 1.x layout) or
  SQLite (single-file).
- **Pluggable remote cache** — S3 (preserves 1.x layout), filesystem,
  Redis (with optional TTL + PR-branch tracking sidecar).
- **Per-example `tracks:` DSL** — annotate any example with extra
  inputs the tracker can't auto-observe (config files, env-var
  branches, non-Ruby deps).
- **Rails preset + auto-detection** — `track_rails_defaults`
  attaches the common Rails-side declared globs in one DSL call;
  the engine attaches view + AR notification subscribers
  automatically when Rails is detected.
- **`bin/rspec-tracer` CLI** — opt-in for local-dev convenience
  (`doctor` / `cache:info` / `cache:clear` / `report:open` /
  `explain <id>`).
- **Boot-time warns** for two common user-trust traps (SimpleCov
  load order; `track_ar_schema_notifications` precondition).
- **Ruby 3.1+ / Rails 7.0+ floors**, Rails 8.0 CI-gated, JRuby 9.4
  supported, RSpec 3.12 / 3.13 supported.

---

## 2.1 — planned

A focused minor release adding one capability and any community-
surfaced polish. The scope below is the committed set; the project
board carries the live list.

- **Per-example precision under Rails `config.eager_load = true`.**
  When `eager_load = true` (the Rails CI default), all `app/` files
  load at boot and trigger the whole-suite invalidator on any
  `app/` edit. Safe but coarser than per-example attribution. The
  2.1 enhancement (working name: `track_class_attribution`) will
  install class-dispatch tracking via `TracePoint(:class)` at boot
  + `TracePoint(:call)` per example to trim invalidator scope to
  examples that actually touched the changed class. Opt-in by
  default (the `TracePoint(:call)` overhead is real); designed
  from scratch on the user-shape problem.

- **Polish + ergonomics gathered from 2.0 feedback** — items
  surfaced via [GitHub Discussions](https://github.com/avmnu-sng/rspec-tracer/discussions)
  and issue triage during the 2.0 series. The project board's
  "Planned (2.1)" column carries the live list.

---

## Considering — 3.0 and beyond

Forward-looking themes; nothing committed. Items move from
"considering" to "planned" when there's a concrete design + a
maintainer commitment to ship. Open a Discussion if any of these
matter to your workflow — community signal directly informs which
move forward.

- **Minitest adapter.** The architecture is RSpec-first today; a
  Minitest adapter is feasible as a separate gem reusing the
  Tracker / Storage / RemoteCache layers.
- **Per-example "explain why this re-ran" UX** beyond the CLI.
  A language-server protocol or VS Code extension surface so the
  reason shows up in the editor next to the failing assertion.
- **Monorepo per-app cache discovery.** `track_rails_defaults`
  with auto-detection of multiple Rails apps under one git root.

---

## Won't do

Out of scope for the rspec-tracer line; better solved by adjacent
tools.

- **Multi-language support** (Python, JS, Go). The tracker is
  Ruby-`Coverage`-bound and the framework hooks are RSpec-bound.
- **Distributed test scheduling.** That's [knapsack_pro](https://docs.knapsackpro.com/) /
  [ci-queue](https://github.com/Shopify/ci-queue) /
  [buildkite-test-splitter](https://buildkite.com/docs/test-splitting).
  rspec-tracer composes with them (the digest-partition primitive
  is exposed) but doesn't schedule.
- **General-purpose build tool.** rspec-tracer is test-scoped;
  build / asset / deployment tracking is out of scope.

---

## How to influence the roadmap

- **Bug reports + concrete feature requests** → [GitHub Issues](https://github.com/avmnu-sng/rspec-tracer/issues).
- **"Is X possible?" / "should rspec-tracer do Y?"** → [GitHub Discussions](https://github.com/avmnu-sng/rspec-tracer/discussions).
- **"I want to contribute"** → [`.github/CONTRIBUTING.md`](.github/CONTRIBUTING.md).
