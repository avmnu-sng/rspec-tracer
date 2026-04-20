# Reporters

Optional output formatters for tracer results. Each reporter is opt-in;
the tracer engine functions with zero reporters attached.

## Responsibilities

- Consume the finalized dependency graph and run outcome.
- Emit output in a specific format (JSON, terminal, HTML, custom).
- Stay out of the hot path — reporters run at finalize, not per-example.

## Planned reporters

- `JsonReporter` — machine-readable run summary.
- `TerminalReporter` — concise stdout summary.
- `HtmlReporter` — five report types (dependency, coverage, examples,
  flaky, slowest) with frontend build.

## Extension

Subclass `Reporters::Base` and register via `config.add_reporter`.

## Status

Placeholder for 2.0. Legacy HTML reporter lives in
`lib/rspec_tracer/html_reporter/` and migrates here during Phase 6
(sessions M6.1, M6.2). Both directories coexist through the Phase 6
transition.
