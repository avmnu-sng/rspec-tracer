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

`file_read_hook` landed later than the other scenarios: 1.x had no
I/O prepend hooks to measure.

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
- `1.10× – 1.30×` — warning (CI posts a PR comment; build passes).
- `> 1.30×` — build fails.
- **`INFO` (informational, not gated)** — scenarios listed in
  `INFORMATIONAL_SCENARIOS` (currently: `parallel_tests_2_workers`)
  print their ratio for trend-watching but never fail the build.
  See "Informational scenarios" below for why.

### Informational scenarios

Some scenarios have inherent wall-clock variance that exceeds the
gate threshold by structural property — they exercise code shapes
where CI-environment factors dominate timing. These scenarios are
reported (timing emitted to stderr + summary markdown) but their
ratio never contributes to the exit code.

The canonical case is `parallel_tests_2_workers`. Its baseline
itself records `p50=0.866 / p95=1.868` — `p95/p50 = 2.16×` within
its own 10-iter sample. Any threshold below 2.16× will fail on
noise alone. Two structural causes compound:

1. **Process contention**: `parallel_rspec` spawns driver + 2 workers
   = 3 Ruby processes on GHA's 2-vCPU runners. Worst-case wall ≈
   `max(worker_wall) + merge`, and per-worker wall is ~2× of dedicated
   on contended CPU.
2. **Worker-startup variance amplified by max-of-N**: each worker
   independently boots Ruby + Bundler + the gem set. The driver
   waits for the slowest. Per-worker startup variance amplifies
   into total wall.

A real regression-detection signal for these scenarios would be a
behavior assertion (cache-merge correctness, no worker crash)
rather than a wall-clock comparison. Wall-clock stays as
informational summary output for trend-watching across runs.

**For gem users**: if you adopt similar wall-clock gates against
your own benchmark of rspec-tracer + parallel_tests, expect
2-3× run-to-run variance on shared CI runners. That's not a
regression — it's an inherent property of `N workers on M vCPUs`
where `N > M` plus shared-runner co-tenancy. Use a wider tolerance
(or no wall-clock gate) for parallel-worker scenarios.

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
ratchet on a GHA runner is a followup; the manual `regen-ratchet`
workflow is the tool for it.

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
