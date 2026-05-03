# Internals

Detailed walkthroughs of how rspec-tracer's subsystems work. These
docs go below the level of [`ARCHITECTURE.md`](../../ARCHITECTURE.md):
that file gives the layered mental model + protocols; these docs walk
the actual code paths for specific scenarios.

Audience: contributors + curious users debugging unexpected behavior.

## Documents

- [`HOW_TRACKS_CASCADES.md`](HOW_TRACKS_CASCADES.md) — the per-example
  `tracks: { files:, env: }` DSL: how nested describes union (rather
  than overwrite) parent metadata, why we ship our own walker instead
  of using RSpec's built-in cascade, and how wildcard env patterns
  expand.
- [`HOW_PARALLEL_TESTS_MERGE.md`](HOW_PARALLEL_TESTS_MERGE.md) — what
  happens when `parallel_tests` runs N workers: per-worker cache
  directory layout, the elected-last-worker pattern, the merge
  algorithm at finalize, and the report-emission ordering that
  ensures users see merged output instead of per-worker noise.
- [`HOW_REMOTE_CACHE_BACKENDS.md`](HOW_REMOTE_CACHE_BACKENDS.md) — the
  three remote-cache backends (S3 / Local-FS / Redis): tier routing
  (main vs PR), branch_refs persistence, retention semantics
  (count + duration + per-PR-branch TTL), and the graceful-degradation
  contract.
- [`HOW_STORAGE_BACKENDS.md`](HOW_STORAGE_BACKENDS.md) — JSON vs SQLite
  on-disk layouts: the 10-file JSON layout (bit-for-bit 1.x compat),
  the SQLite schema, the schema_version cold-run policy, and how the
  backends compose with the optional MessagePack serializer.

## When to read which doc

- **"Why didn't my `tracks:` annotation narrow this re-run?"** →
  [`HOW_TRACKS_CASCADES.md`](HOW_TRACKS_CASCADES.md).
- **"Why is my parallel_tests run producing N report directories?"** →
  [`HOW_PARALLEL_TESTS_MERGE.md`](HOW_PARALLEL_TESTS_MERGE.md).
- **"Why did the cache fall back to cold on a PR build?"** →
  [`HOW_REMOTE_CACHE_BACKENDS.md`](HOW_REMOTE_CACHE_BACKENDS.md).
- **"What does the on-disk cache actually look like?"** →
  [`HOW_STORAGE_BACKENDS.md`](HOW_STORAGE_BACKENDS.md).

For the **why** behind any architectural choice (separate from the
**how** these docs describe), see
[`../../ARCHITECTURE.md`](../../ARCHITECTURE.md)'s "Input taxonomy"
section.
