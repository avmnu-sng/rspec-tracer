# Roadmap

This is the public roadmap for rspec-tracer. The **live status** of
specific work items lives on the
[rspec-tracer roadmap project board](https://github.com/users/avmnu-sng/projects/1).

This file summarizes phases at a high level — what shipped, what's
next, what's being considered. Detail per item lives in
[`CHANGELOG.md`](CHANGELOG.md), the project board, and the linked
issues / PRs.

---

## 2.0 — in pre-release

The 2.0 line is a ground-up architecture rewrite around the
input-taxonomy mental model: every test is a pure function of its
inputs; tracking is input identification; cache invalidation is
input-digest mismatch. Currently on `2.0.0.pre.2`; observation
window open before the next pre-release / rc cut.

The full per-release feature list is in [`CHANGELOG.md`](CHANGELOG.md).
The headline themes already shipped:

- **Pluggable storage** — JSON (default; preserves 1.x layout) or
  SQLite (single-file).
- **Pluggable remote cache** — S3 (preserves 1.x layout), filesystem,
  Redis (with optional TTL + PR-branch tracking sidecar).
- **Per-example `tracks:` DSL** — annotate any example with extra
  inputs the tracker can't auto-observe (config files, env-var
  branches, non-Ruby deps).
- **Rails preset + auto-detection** — `track_rails_defaults` attaches
  the common Rails-side declared globs in one DSL call; the engine
  attaches view + AR notification subscribers automatically when
  Rails is detected.
- **`bin/rspec-tracer` CLI** — opt-in for local-dev convenience
  (`doctor` / `cache:info` / `cache:clear` / `report:open` /
  `explain <id>`).
- **Flaky-test detection** — automatic transition into `:flaky`
  registry status on across-run and within-run-retry fail→pass
  patterns. Surfaces in the HTML reporter's Flaky tab. (Restored
  in `2.0.0.pre.2` after a regression in the early 2.0 rewrite.)
- **Stable `example_id` across cosmetic edits** — no thrash on
  blank-line edits, no load-order flip across files sharing a
  `describe` name, no line-shift instability on unnamed
  `it { ... }` / `specify { ... }` matchers. (Pervasive long-standing
  bug since v1.0.0; fully closed in `2.0.0.pre.2`.)
- **Boot-time warns** for two common user-trust traps (SimpleCov
  load order; `track_ar_schema_notifications` precondition).
- **Ruby 3.1+ / Rails 7.0+ floors**, Rails 8.0 CI-gated, JRuby 9.4
  supported, RSpec 3.12 / 3.13 supported, Ruby HEAD + TruffleRuby
  on best-effort tier.

---

## What's coming before 2.0 final

The remaining work in the 2.0 line, organized by theme. Specific items
move between rc cycles as the project board shows live; the high-level
shape:

### Trust + observability (the central focus)

The single most-requested area from pre-release feedback. The strategic
bet for 2.0 final is to make correctness **provable**, not just claim it.
Items:

- **Shadow / audit mode.** Run the full suite without skipping anything;
  record what *would* have been skipped and which (if any) of those
  would have failed. Designed for teams to run silently in CI for 2-3
  weeks to accumulate empirical "0 missed failures across N runs"
  evidence before flipping the switch. The canonical adoption ramp for
  correctness-sensitive infrastructure. Lands in `v2.0.0.rc.2`.
- **Soundness tier documentation.** Explicit classification of what
  rspec-tracer guarantees: **sound** (file-content digests, explicit
  `tracks:`, env snapshot), **conservative** (boot-set whole-suite
  invalidator, Rails `lib/` engine-load fallback), **heuristic** (Rails
  subscriber attribution under common configs), **blind spot** (runtime
  metaprogramming, monkey-patches, hidden reflection -- called out
  prominently). Shipped -- see
  [ARCHITECTURE.md](ARCHITECTURE.md#soundness-model).
- **`safety_mode :paranoid | :balanced | :aggressive` preset DSL.**
  Named presets that toggle existing knobs (`transitive_load_tracking`,
  `whole_suite_invalidators`, `always_re_run_failed_examples`,
  per-example `tracks:`) so risk-averse teams can adopt in steps. The
  default stays balanced; paranoid widens invalidation; aggressive
  trusts inference more.
- **`bin/rspec-tracer blast-radius <file_path>` CLI.** Inverse of
  `explain`. Outputs *"if you modify this file, it triggers N examples
  across M files."* Lets developers spot architectural drift before
  the PR review; turns the dependency graph from invisible infra into
  inspectable insight.
- **`bin/rspec-tracer explain --not-run <example_id>`.** The "why
  did this NOT run?" inverse of the existing `explain`. Closes the
  most-requested observability gap from pre-release.
- **Confidence scoring on per-run summary.** Terminal output extends
  to show what proportion of selection decisions came from explicit
  vs inferred dependencies; surfaces invalidation hotspots.
- **Auto-fallback when self-measured confidence is low.** Runtime
  decision logic that consumes the confidence score: if confidence
  drops below a configurable threshold OR N consecutive runs show
  downward drift, automatically fall back to full-suite execution
  with a clear warn line. Converts the trust story from
  *observe-and-report* to *observe-and-self-defend* — the tool
  structurally cannot skip silently when its own confidence is low.

### Flaky detection as first-class

Building on the restored `:flaky` registry status:

- **Auto-quarantine for N consecutive flake observations.** Configurable
  threshold; a flaky example is automatically skipped from the
  determine-failure decision until the user clears it. Reduces the
  "flaky test broke our build" overhead. Competitive with paid SaaS
  flaky-test analytics platforms.
- **Flaky-test trending.** Which specs became flaky recently; which
  are intermittent vs persistently flaky; per-spec quarantine timeline.
  Surfaces in the HTML reporter as a first-class tab.

### Rails per-example precision under `eager_load = true`

Currently when `config.eager_load = true` (Rails CI default), all
`app/` files load at boot and any `app/` edit triggers the whole-suite
invalidator — safe but coarser than per-example attribution.

- **`track_class_attribution` config DSL** (opt-in by default). Installs
  class-dispatch tracking via `TracePoint(:class)` at boot +
  `TracePoint(:call)` per example to trim invalidator scope to examples
  that actually touched the changed class. The `TracePoint` overhead is
  real and documented; users opt in per their cost / precision trade-off.
  *(Originally planned for 2.1; promoted to the 2.0 final scope because
  per-example precision under the most common Rails CI configuration is
  a trust story, not a feature story. Implementation is evidence-gated
  on shadow-mode data + reference-adopter feedback during rc.3 — if
  whole-suite invalidation under `eager_load = true` proves not to be
  the binding constraint on real-world Rails apps, the feature defers
  back to 2.1.)*

### Documentation + positioning

The same release ramp also reshapes how rspec-tracer is presented:

- **README restructured** as a conversion-oriented landing page (one
  benchmark number, one setup command, one safety-story sentence, then
  depth links). The 6-bucket input taxonomy and engineering-depth
  material moves to ARCHITECTURE.md / COOKBOOK.md where it already
  partially lives.
- **Cost framing in plain dollars + CI-minutes** — the value made
  legible to the platform-team buyer, not just the developer adopter.
- **CI-recipes discoverability** — `docs/CI_RECIPES.md` (translations
  of the GHA cache pattern to CircleCI / GitLab CI / Buildkite /
  Heroku CI) surfaced prominently in the README so teams can plug in
  without writing custom orchestration.
- **Data-stays-local positioning** — explicit framing that rspec-tracer
  runs entirely inside customer infrastructure (no telemetry, no
  per-seat cost, no vendor egress). Material for regulated industries
  where commercial test-optimization SaaS isn't viable.
- **Stated Ruby support / EOL policy** in the README's
  [Maintenance section](README.md#maintenance). Closes
  "single-maintainer infrastructure on volatile tooling" as an
  adoption objection.

### Distribution + adoption

Running in parallel with the engineering cycles above — not after
2.0 ships. The recognition: after the rc cycles complete, the
binding constraint flips from *"is the tool trustworthy enough"*
to *"does anyone know it exists and will a credible team vouch
for it."* Owned as a first-class workstream rather than treated
as an afterthought.

- **Reference adopter recruitment + first public case study.**
  Warm-target outreach to known active users + co-authored case
  study published alongside the GA tag. Self-reported maintainer
  benchmarks are discounted by default; third-party *"we cut CI
  from N min to M min, here's the config"* is the artifact that
  closes adoption-side Q&A loops.
- **Conference talks + technical blog series.** CFP submissions
  for RubyConf / Rails World in the GA window; 3-part blog series
  anchored to the trust + soundness-ledger narrative; newsletter
  pitches to Ruby Weekly + This Week in Rails.
- **Ongoing community presence.** Maintainer presence in
  3+ Ruby/Rails community real-time channels (Discord / Slack)
  with sustained ~1-2 hr/week cadence. Lower-overhead than
  conferences/blog but compounds over time.

The distribution workstream feeds the engineering cycles too:
reference-adopter feedback empirically validates whether
`track_class_attribution` under `eager_load = true` is the
binding constraint adopters care about (vs a theoretical concern),
which influences whether that feature lands in 2.0 GA or defers
back to 2.1.

---

## 2.0 — final

When the items above have shipped + observed + community feedback
has been bucketed, `2.0.0` final tags. Target: late summer / early
fall 2026. The "what's in 2.0" list at that point will be the
shipped section above + this in-flight section consolidated.

A **published soundness ledger** lands alongside 2.0 final: shadow
mode run against 4-5 open-source Rails suites (Mastodon, Spree,
Solidus, Refinery, plus 1-2 to be decided) with the false-skip count
+ false-pass count + postmortems published to gh-pages under a stable
URL. Refreshes periodically. The empirical trust artifact that
validates the algorithm against real workloads, not maintainer
benchmarks.

---

## 2.1 — planned

A focused minor release adding capability + polish gathered from 2.0
feedback. The scope below is the committed direction; the project
board carries the live list as items firm up.

- **Anti-pattern detection** — turning the dependency graph into a
  test-health analyzer. Specific detectors:
  - **Order-dependent specs** — compare dep graphs across `--order
    random` seeds; flag specs that resolve differently.
  - **Invalidation hotspots** — files whose edits would invalidate
    more than N% of the suite; surfaces tight coupling.
  - **Over-coupled specs** — examples that depend on more than N
    files; suggests refactor candidates.
- **Dependency graph visualization** — `rspec-tracer graph <spec_path>`
  for terminal-ASCII output, plus an HTML view. Same data the tracker
  already maintains, surfaced as inspectable infrastructure.
- **DatabaseCleaner strategy-aware narrowing** — the residual narrow-
  attribution gap when DatabaseCleaner truncation / transaction
  strategies fire `sql.active_record` events inside the per-example
  bucket. Today's boot-time warn explains the trade-off; 2.1 closes it.
- **Polish + ergonomics gathered from 2.0 feedback** — items surfaced
  via [GitHub Discussions](https://github.com/avmnu-sng/rspec-tracer/discussions)
  and issue triage during the 2.0 series. The project board's
  "Planned (2.1)" column carries the live list.

---

## 2.2 and beyond — considering

Forward-looking themes; nothing committed. Items move from
"considering" to "planned" when there's a concrete design + a
maintainer commitment to ship. Open a Discussion if any of these
matter to your workflow — community signal directly informs which
move forward.

- **Replay mode** — `rspec-tracer replay <commit_sha>` for CI
  debugging investigations. Re-run the selective decision against
  a historical commit's state to understand why a past run made
  the choices it did.
- **Deeper ActiveJob / ActionMailer / initializer attribution** —
  the residual Rails-specific attribution surface that 2.0 +
  `track_class_attribution` don't reach.
- **Minitest adapter.** The architecture is RSpec-first today; a
  Minitest adapter is feasible as a separate gem reusing the
  Tracker / Storage / RemoteCache layers.
- **Editor-side observability** — per-example "explain why this
  re-ran" surfaced in an LSP or VS Code extension, so the reason
  shows up next to the failing assertion.
- **Monorepo per-app cache discovery** — `track_rails_defaults`
  with auto-detection of multiple Rails apps under one git root.
- **Plugin / custom-tracker extension point** — first-class API for
  teams to write their own dependency-detection mechanism for the
  ~5% blind spot Ruby's dynamism leaves.

---

## Won't do

Out of scope for the rspec-tracer line; better solved by adjacent
tools or different products entirely.

- **Multi-language support** (Python, JS, Go). The tracker is
  Ruby-`Coverage`-bound and the framework hooks are RSpec-bound.
- **Distributed test scheduling.** That's [knapsack_pro](https://docs.knapsackpro.com/) /
  [ci-queue](https://github.com/Shopify/ci-queue) /
  [buildkite-test-splitter](https://buildkite.com/docs/test-splitting).
  rspec-tracer composes with them (the digest-partition primitive
  is exposed) but doesn't schedule.
- **General-purpose build tool.** rspec-tracer is test-scoped;
  build / asset / deployment tracking is out of scope.
- **Bazel-grade soundness in a dynamic language.** Ruby's
  metaprogramming makes Bazel-style declared-graph soundness
  impossible to deliver honestly. rspec-tracer's approach is
  *observable* soundness — explicit guarantees on what is and
  isn't tracked, plus shadow-mode empirical verification, plus
  opt-in `tracks: { ... }` for the residual blind spot. Trust comes
  from honesty about the limits, not from claiming Bazel parity.
- **AI-assisted test generation.** Different product. Not what
  rspec-tracer is.
- **PR risk scoring + selective-review routing.** Different products,
  even though the dependency graph could in principle feed them.
  rspec-tracer stays focused on test selection + test health; if
  someone wants to build the broader code-intelligence platform on
  top, the graph is exposed for that — but it's a separate project.
- **Telemetry / usage analytics.** The "data never leaves your
  infrastructure" property is a deliberate design choice and a
  competitive differentiator. rspec-tracer will not collect
  telemetry, even anonymous opt-in. Visibility into adoption comes
  from Discussions, issues, and case studies.

---

## How to influence the roadmap

- **Bug reports + concrete feature requests** → [GitHub Issues](https://github.com/avmnu-sng/rspec-tracer/issues).
- **"Is X possible?" / "should rspec-tracer do Y?"** → [GitHub Discussions](https://github.com/avmnu-sng/rspec-tracer/discussions).
- **"I want to contribute"** → [`.github/CONTRIBUTING.md`](.github/CONTRIBUTING.md).
- **Sponsoring maintenance** → sponsorship channels (GitHub Sponsors
  / OpenCollective) are under consideration. Open a Discussion if
  your team would sponsor a release cadence or specific feature
  build-out — concrete commitments inform whether and how to set
  these up.

---

## Maintenance + sustainability

rspec-tracer is a single-maintainer project at the time of writing.
The concrete steps taken to mitigate the bus-factor objection that
platform teams legitimately raise on infrastructure adoption:

- **Stated Ruby support window.** rspec-tracer commits to supporting
  Ruby versions until upstream Ruby Core reaches EOL plus 6 months.
  Currently CI-gated per the [README's Quick start](README.md#quick-start):
  Ruby 3.1, 3.2, 3.3, 3.4, 4.0 + JRuby 9.4. The version-by-version
  EOL table lives in the [README Maintenance section](README.md#maintenance).
- **Ruby HEAD + TruffleRuby on a best-effort tier.** Neither is
  CI-gated on every PR, but breakage reported on a Ruby prerelease
  is treated as a high-priority bug, not a future-self problem. Goal:
  rspec-tracer should never be the reason a team can't upgrade Ruby.
- **Open governance commitment.** Sponsorship channels (GitHub
  Sponsors / OpenCollective) are under consideration; if your team
  would sponsor a release cadence or specific feature build-out,
  open a Discussion. Concrete sponsorship interest informs whether
  to set these up.
- **All planning artifacts public** (this roadmap + project board +
  CHANGELOG + ARCHITECTURE + soundness ledger when it ships).
  Nothing strategic lives only in the maintainer's head.

If you're evaluating rspec-tracer for production use and the
single-maintainer status is your blocker, [open a Discussion](https://github.com/avmnu-sng/rspec-tracer/discussions/new) — the
maintainer welcomes co-maintainer onboarding conversations and
explicit governance commitments.
