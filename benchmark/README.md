# rspec-tracer benchmark harness

Measures rspec-tracer's overhead across four scenarios and enforces a
ratchet to catch performance regressions before they land.

## Scenarios

| Name | What it measures | Fixture |
|---|---|---|
| `cold_ruby`  | Cold-start RSpec with tracer on an empty cache | `benchmark/fixtures/ruby_app` |
| `warm_noop`  | Re-run with cache populated, no file changes  | same |
| `cache_load` | Just `Cache#populate_from_disk` + process exit | same |
| `cold_rails` | Cold RSpec against the Rails fixture (model specs only) | `spec/fixtures/rails_app` |

`file_read_hook` is in the brief but deferred to M3.2 — 1.x has no I/O
prepend hooks to measure.

## Running

```sh
task benchmark:smoke                # ~3s; cold_ruby + warm_noop + cache_load
task benchmark:full                 # ~15s; all four scenarios
task benchmark:ratchet:update       # regenerates benchmark/ratchet.json (requires --yes)
```

Or directly:

```sh
ruby benchmark/harness.rb --smoke
ruby benchmark/harness.rb --full --ratchet benchmark/ratchet.json
ruby benchmark/harness.rb --full --update-ratchet benchmark/ratchet.json --yes
```

## Output

Each scenario prints one JSON line to stdout:

```json
{"scenario":"cold_ruby","iterations":5,"timings":[0.34,0.25,0.26,0.26,0.25],"p50":0.26,"p95":0.34,"env":{"ruby":"3.3.10","ruby_platform":"arm64-darwin24","os":"darwin24","cpu":"Apple M2 Max","cores":12,"recorded_at":"2026-04-20T11:30:00Z"}}
```

A human summary goes to stderr.

## Ratchet policy

`benchmark/ratchet.json` records the baseline P50 + P95 timings per
scenario. The harness compares each scenario's run-time P50 to the
ratchet's P50:

- `≤ 1.10×` threshold — silent pass.
- `1.10× – 1.20×` — warning (CI posts a PR comment; build passes).
- `> 1.20×` — build fails.

### When to update the ratchet

- **Intentional regression** — e.g., a new instrumentation has a known
  cost. Update the ratchet in the same PR; explain in the commit body
  why the threshold moved.
- **Hardware drift** — runner image upgrade changes baseline. Flag in
  the commit message.
- **Never as a silent "make CI green" hack.** Reviewer responsibility:
  scrutinise every ratchet change.

### Current baseline

The committed `ratchet.json` was generated on Ruby 3.3.10 / Apple M2 Max
/ macOS. **CI runs on GHA `ubuntu-latest` (~2-core VMs) are 3-5× slower
— the CI benchmark job posts a PR comment but does NOT enforce the
ratchet until a CI-generated baseline is committed.** Regenerating the
ratchet on a GHA runner is a followup (touched in the M2.4 handoff
notes).

## Adding a scenario

1. Add an entry to `SCENARIOS` in `benchmark/harness.rb` with `cwd`,
   `cmd`, `env`, optional `cleanup` paths (removed before each
   iteration for cold-state enforcement), `warmup` Proc (runs once
   before timing), `setup` Proc (not timed; e.g. `db:test:prepare`),
   and `smoke: true` if it should run under `--smoke`.
2. Regenerate the ratchet: `task benchmark:ratchet:update` — inspect
   the diff, commit both the scenario and the new ratchet in the same
   PR.
3. Update this README with a one-line description of the scenario.
