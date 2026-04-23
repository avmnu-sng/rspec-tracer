# Fuzz tests

Fuzz harnesses feed random byte sequences into parsers / loaders and
record whether anything crashes (or lets an exception escape the gem).
The goal is **graceful degradation**: every input, no matter how broken,
ends in either a clean load or a recorded and-then-logged failure —
never in tearing down the host test suite.

Fuzz runs are **not per-PR**: smoke is a local sanity check; the full
10k run is scheduled nightly in CI.

## Running

    ITERATIONS=100   bundle exec ruby spec/fuzz/json_backend_fuzz.rb   # smoke
    ITERATIONS=10000 bundle exec ruby spec/fuzz/json_backend_fuzz.rb   # full
    task test:fuzz:smoke        # wrapper (100 iter)
    task test:fuzz:full         # wrapper (10000 iter)

## Reproducibility

Every run prints the PRNG seed. To replay:

    SEED=<n> ITERATIONS=<n> bundle exec ruby spec/fuzz/json_backend_fuzz.rb

## Current harnesses

| File                     | Target                                                              |
|--------------------------|---------------------------------------------------------------------|
| `json_backend_fuzz.rb`   | `RSpecTracer::Storage::JsonBackend#load_graph` on arbitrary bytes   |

Today the harness only fires truly-random bytes, so the outcome
distribution is dominated by parser-level failures that the backend
rescues into nil. Broader coverage (valid-UTF-8 garbage,
valid-JSON/wrong-shape, structural corruption of deeper cache files)
is deliberately deferred to a later dedicated fuzz milestone.

## Writing a new harness

Pick a loader method, write random bytes to the file it reads, call it
inside a `rescue Exception` block, count what escapes. Must not crash
on any input. Must not rely on external network.
