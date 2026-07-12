# Fuzz tests

Fuzz harnesses feed random byte sequences into parsers / loaders and
record whether anything crashes (or lets an exception escape the gem).
The goal is **graceful degradation**: every input, no matter how broken,
ends in either a clean load or a recorded and-then-logged failure —
never in tearing down the host test suite.

Smoke is a local sanity check; the full 10k run executes on every PR
and every push to `main` via the `lint-and-specs` workflow.

## Running

    ITERATIONS=100   bundle exec ruby spec/fuzz/<harness>.rb   # smoke
    ITERATIONS=10000 bundle exec ruby spec/fuzz/<harness>.rb   # full
    task test:fuzz:smoke        # wrapper — 100 iter against all 3 harnesses
    task test:fuzz:full         # wrapper — 10000 iter against all 3 harnesses

## Reproducibility

Every run prints the PRNG seed. To replay:

    SEED=<n> ITERATIONS=<n> bundle exec ruby spec/fuzz/<harness>.rb

## Current harnesses

| File                       | Target                                                                                                  |
|----------------------------|---------------------------------------------------------------------------------------------------------|
| `json_backend_fuzz.rb`     | `RSpecTracer::Storage::JsonBackend#load_graph` (`:json` serializer) on arbitrary bytes.                 |
| `cache_loader_fuzz.rb`     | All 3 backends — `JsonBackend :json` + `JsonBackend :msgpack` (zlib + MessagePack pipeline) + `SqliteBackend` (sqlite3 C bindings). Iterations split evenly per backend. |
| `coverage_adapter_fuzz.rb` | `Tracker::CoverageAdapter#compute_diff` against pathological coverage maps — mixed nil / huge counts / negative ints / Hash vs Array shapes / mode flips. |

`json_backend_fuzz.rb` stays focused on the `:json` decode path; it is
the original harness and runs with the highest iteration
budget per backend. `cache_loader_fuzz.rb` extends fuzz coverage to
the full backend surface (msgpack + sqlite). `coverage_adapter_fuzz.rb`
broadens beyond storage into the tracker hot path - exercises
`compute_diff`'s nil-tolerant + length-divergent branches that load_graph
fuzz cannot reach.

## Writing a new harness

Pick a loader method, write random bytes to the file it reads, call it
inside a `rescue Exception` block, count what escapes. Must not crash
on any input. Must not rely on external network.
