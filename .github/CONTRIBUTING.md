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
- **Taskfile is the dev loop.** `bundle exec rake` is a legacy path
  kept only for the cucumber integration suite; it is removed in
  2.0.0.

See `task --list` for the full command catalogue.

## License

By contributing, you agree your code ships under the project's
[MIT license](../LICENSE).
