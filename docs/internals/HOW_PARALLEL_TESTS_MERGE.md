# How `parallel_tests` workers coordinate + merge

`parallel_tests` runs your suite across N worker processes. Each
worker has its own tracker instance, its own cache directory, and
its own report directory. At finalize, one elected worker merges
everything into top-level outputs.

This doc walks the lifecycle: detection → per-worker isolation →
last-process election → merge → report emission → cleanup.

## Detection at boot

`RSpecTracer.start` checks `RSpecTracer::RSpec::ParallelTests.active?`,
which returns `true` if `ParallelTests.first_process?` resolves
without raising (which it does only when `parallel_tests` set the
environment).

Memoized as `RSpecTracer.parallel_tests?`. Every downstream
component branches on this flag.

## Per-worker directory layout

Each worker writes into a per-worker subdirectory under each of the
3 canonical directories:

```
rspec_tracer_cache/
├── parallel_tests_1/      ← worker 1
│   ├── last_run.json
│   └── <run_id>/
│       └── ... (10 files)
├── parallel_tests_2/      ← worker 2
│   └── ...
└── ... (etc.)

rspec_tracer_coverage/
├── parallel_tests_1/
└── ...

rspec_tracer_report/
├── parallel_tests_1/
└── ...
```

The per-worker subdir name comes from `Configuration#parallel_tests_id`:
`parallel_tests_<TEST_ENV_NUMBER>`. So worker N's `cache_path` is
`<root>/rspec_tracer_cache/parallel_tests_<N>`.

This isolation is mandatory: workers run concurrently with no shared
locks on cache writes. Without per-worker dirs, two workers writing
to `last_run.json` simultaneously would corrupt each other's state.

## Last-process election

After all workers finish their examples, ONE elected worker runs
`finalize!` to merge per-worker outputs into top-level files.

Election uses `ParallelTests.first_process?` — a property of the
parent's worker spawn order, NOT a runtime race. The parent
`parallel_tests` process labels worker 1 with `TEST_ENV_NUMBER=` (or
`'1'` depending on version); subsequent workers get `'2'`, `'3'`,
etc. Worker 1 is always the elected last-process.

We previously used a lock-file election (max `TEST_ENV_NUMBER`-by-
mtime), which raced under slow CI: a fast worker reaching `at_exit`
before the slowest worker had even loaded `spec_helper` would self-
elect, leading to two workers both trying to merge. The
`ParallelTests.first_process?` API resolves this without races —
parent-set env, never updated post-spawn.

## The finalize! lifecycle

The elected worker runs:

1. **`wait_for_other_processes_to_finish`** — blocks on the per-
   worker pid table until the last peer has exited.
2. **`merge_snapshot!`** — walks every `parallel_tests_N/<run_id>/`
   directory, loads the per-worker snapshots via JsonBackend, and
   unions:
   - `all_examples` — Set of every example_id seen by any worker.
   - `all_files` — Set of every dependency file across all workers.
   - `dependency` — Hash[example_id => Set<file>], unioning per-
     worker entries (an example_id only appears in one worker's
     output, so no merge conflict).
   - `boot_set` — Set of files loaded at boot time (intersected
     across workers, since boot-set is per-process; the union would
     over-attribute to examples that didn't actually load all of
     them).
   - `whole_suite_invalidators` — Set of files whose change
     invalidates everything; identical across workers (computed
     from declared-globs at boot).
   - `env_snapshot` — Hash[env_name => digest]; identical across
     workers since env is per-process and parent-spawned.
3. **`emit_merged_reporters!`** — emits HTML / JSON / terminal
   reports against the MERGED top-level snapshot, into the top-
   level `rspec_tracer_report/` (NOT `rspec_tracer_report/
   parallel_tests_N/`). This produces the single user-visible report
   set.
4. **`purge_worker_dirs!`** — removes every `parallel_tests_N/`
   subdirectory under the cache + coverage + report roots. The
   merged output supersedes the per-worker raw data.
5. **`remove_lock_file!`** — deletes `rspec_tracer.lock` so the
   next run starts clean.

## Why reporters emit AFTER merge, not per-worker

Pre-2.0 (and in some early 2.0 betas), per-worker `at_exit`
emitted reports into each `rspec_tracer_report/parallel_tests_N/`
directory, then `purge_worker_dirs!` removed those directories.
Net result: every parallel_tests user got ZERO usable reports at
run-end.

The fix gates `emit_reporters` on `!parallel_tests?` in
`run_exit_tasks` (per-worker emission no-ops) and adds
`emit_merged_reporters!` to the elected worker's `finalize!` chain
AFTER `merge_snapshot!` (so the merged top-level cache exists) and
BEFORE `purge_worker_dirs!` (so the merged top-level reports
exist when purge runs).

The merged emission is wrapped in its own rescue so a failed
reporter doesn't block purge / lock cleanup (graceful degradation
contract).

## Coverage merging

Coverage data from `::Coverage.peek_result` is per-process and not
trivially mergeable. Each worker writes its own `coverage.json` to
`rspec_tracer_coverage/parallel_tests_N/`; users typically rely on
SimpleCov's own collation (which understands the per-worker layout
via `SimpleCov.collate`).

If you don't use SimpleCov + you need merged coverage, your
collation step happens AFTER rspec-tracer's `purge_worker_dirs!`
runs. Workaround: copy the per-worker files to a sibling location
in a `before(:suite)` shutdown hook.

## Interruption recovery

Killing the parent `parallel_rspec` process mid-run leaves the
lock file (`rspec_tracer.lock`) in place. The next run sees the
stale lock and refuses to start.

Recovery:

```sh
rm -f rspec_tracer.lock && bundle exec parallel_rspec spec/
```

We don't auto-clean the lock at startup because doing so would mask
genuine concurrency bugs: if two `parallel_rspec` invocations were
running simultaneously, auto-cleanup of the lock would let them
collide.

## Caveats

- **TruffleRuby `parallel_tests`**: the `ParallelTests.first_process?`
  API works on TruffleRuby but the cell is best-effort
  (`continue-on-error` in CI). Per-worker spawn timing is more
  variable on TruffleRuby's runtime.
- **`TEST_ENV_NUMBER`+`TEST_SUITE_ID` interaction**: when both env
  vars are set (e.g. sharded CI suite running parallel_tests
  inside each shard), the cache_path nests:
  `<root>/rspec_tracer_cache/<TEST_SUITE_ID>/parallel_tests_<N>/`.
  Merge happens within one shard; cross-shard merging is not
  rspec-tracer's concern (the remote-cache backend handles
  cross-shard distribution).
- **Custom storage backends + parallel_tests**: a custom
  storage backend MUST handle per-worker isolation itself. The
  default JSON / SQLite backends key off `cache_path`; a custom
  backend writing to a single shared SQL database would need its
  own per-worker scoping (e.g. `WHERE worker_id = ?` filters).

## Where to read code

- `lib/rspec_tracer/rspec/parallel_tests.rb` — election + lifecycle
  hooks.
- `lib/rspec_tracer/storage/json_backend.rb` (`Merger` class) — the
  per-field merge implementations.
- `spec/integration/parallel_tests_spec.rb` — end-to-end test
  driving the actual fixture under `parallel_rspec`.
