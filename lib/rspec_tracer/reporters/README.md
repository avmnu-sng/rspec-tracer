# Reporters

Output formatters for tracer results. Each reporter is pluggable via
`config.add_reporter`; the tracer engine functions with zero reporters
attached. Reporters sit above the Tracker + Storage layers, consume
the finalized `Storage::Snapshot`, and emit to `report_dir`.

## Files

| File                    | Role                                                                   |
|-------------------------|------------------------------------------------------------------------|
| `base.rb`               | Abstract `Reporters::Base` with `initialize(snapshot:, report_dir:, run_metadata:, logger:, **opts)`, `generate`, `no_op?`. |
| `payload_builder.rb`    | `Reporters::PayloadBuilder` — shared schema-v1 payload builder consumed by both JSON and HTML. |
| `json_reporter.rb`      | `Reporters::JsonReporter` — writes `report_dir/report.json` with schema version 1; 5 report types. |
| `terminal_reporter.rb`  | `Reporters::TerminalReporter` — concise stdout summary (≤ 5 lines); respects `NO_COLOR`. |
| `html_reporter.rb`      | `Reporters::HtmlReporter` — writes `report_dir/index.html` (Preact bundle + server-rendered fallback tables). |
| `registry.rb`           | `Reporters::Registry` — resolves configured reporters, rescues per-reporter, warns + continues on failure. |
| `html/`                 | Committed frontend toolchain (Preact + Vite). See [html/README.md](html/README.md). |

## Configuration

```ruby
# .rspec-tracer
add_reporter :terminal
add_reporter :json
add_reporter MyCustomReporter, color: false
```

Symbols resolve via `Registry::BUILT_INS` (`:terminal`, `:json`,
`:html`). Class values pass through — must duck-type
`Reporters::Base`. If no `add_reporter` calls are made, `Registry`
defaults to `[:terminal, :json, :html]`.

## JSON schema (version 1)

`<report_dir>/report.json` envelope:

```json
{
  "schema_version": 1,
  "run_id": "<hex>",
  "generated_at": "<ISO-8601>",
  "summary": { "total_examples": N, "passed_examples": N, "..." : "..." },
  "reports": {
    "all_examples": [...],
    "duplicate_examples": [...],
    "flaky_examples": [...],
    "examples_dependency": [...],
    "files_dependency": [...]
  }
}
```

Additive fields on existing objects are non-breaking. Removing or
renaming a top-level key bumps `SCHEMA_VERSION`. Full field list
lives in `json_reporter.rb`'s documentation comment.

## Graceful degradation

Every reporter runs inside an isolated rescue in `Registry#emit_all`.
A raising reporter logs a warning via `configuration.logger.warn` and
emission continues with the next reporter. This matches the Storage
backend contract — a tracer failure never propagates a non-zero exit
into the user's test suite.

## Extension

Subclass `Reporters::Base`:

```ruby
class MySlackReporter < RSpecTracer::Reporters::Base
  def generate
    return if no_op?

    post_to_slack(snapshot, report_dir, run_metadata)
  end
end
```

Register via `config.add_reporter MySlackReporter, webhook_url: ENV['SLACK_URL']`.

## HTML reporter

`HtmlReporter` emits `<report_dir>/index.html` plus a sibling
`assets/` directory containing the pre-built bundle (Preact + CSS).
The frontend source + build tooling live in
[`html/`](html/README.md); `dist/` is committed so users never run
`npm`. Rebuild maintainer-side via `task reporters:html:build`.

The reporter renders two layers:

1. A `<script id="report-data" type="application/json">` payload
   built by `PayloadBuilder` (same payload JSON reporter writes,
   minus the pretty-print).
2. Server-rendered fallback `<table>` elements for every report
   type. If JavaScript is disabled or the bundle fails to load,
   these stay in the DOM and remain readable; when Preact hydrates,
   the bundle removes the fallback and renders the interactive
   view.

This two-layer approach is load-bearing for the "works without
JavaScript" AC — the reporter output is a usable read even in
degraded environments.
