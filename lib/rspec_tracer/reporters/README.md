# Reporters

Output formatters for tracer results. Each reporter is pluggable via
`config.add_reporter`; the tracer engine functions with zero reporters
attached. Reporters sit above the Tracker + Storage layers, consume
the finalized `Storage::Snapshot`, and emit to `report_dir`.

## Files

| File                    | Role                                                                   |
|-------------------------|------------------------------------------------------------------------|
| `base.rb`               | Abstract `Reporters::Base` with `initialize(snapshot:, report_dir:, run_metadata:, logger:, **opts)`, `generate`, `no_op?`. |
| `json_reporter.rb`      | `Reporters::JsonReporter` — writes `report_dir/report.json` with schema version 1; 5 report types. |
| `terminal_reporter.rb`  | `Reporters::TerminalReporter` — concise stdout summary (≤ 5 lines); respects `NO_COLOR`. |
| `registry.rb`           | `Reporters::Registry` — resolves configured reporters, rescues per-reporter, warns + continues on failure. |

## Configuration

```ruby
# .rspec-tracer
add_reporter :terminal
add_reporter :json
add_reporter MyCustomReporter, color: false
```

Symbols resolve via `Registry::BUILT_INS` (`:terminal`, `:json`;
M6.2 adds `:html`). Class values pass through — must duck-type
`Reporters::Base`. If no `add_reporter` calls are made, `Registry`
defaults to `[:terminal, :json]`.

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

M6.1 ships Terminal + JSON. M6.2 adds HTML (`reporters/html_reporter.rb`
+ frontend build under `reporters/html/`). The legacy
`lib/rspec_tracer/html_reporter/` tree remains in-tree through M6.2
transition and is retired in the same PR that ships the new HTML
reporter.
