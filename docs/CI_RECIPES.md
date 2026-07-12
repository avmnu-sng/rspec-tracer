# CI recipes for rspec-tracer

The canonical GitHub Actions pattern lives at
[`.github/workflows/example-tracer-cache.yml`](../.github/workflows/example-tracer-cache.yml).
This doc translates the same cache-key shape to four other
popular CI providers — **CircleCI**, **GitLab CI**, **Buildkite**,
and **Heroku CI**. The cache contract is the same on every platform:

> Persist `rspec_tracer_cache/` across runs, keyed on the inputs that
> change the cache layout: OS + Ruby version + rspec-tracer gem
> version + project Gemfile.

If any of those four inputs differs, the cache is invalidated and
the next run is cold. If all four match, the next run restores the
prior cache and rspec-tracer skips unchanged examples per its
dependency-tracking contract.

## Cache key shape

The 4-component canonical key (per
[ARCHITECTURE.md](../ARCHITECTURE.md)) is:

```
<os>-<ruby-version>-<tracer-version>-<gemfile-hash>
```

- **`<os>`** — runner platform (`linux` / `macos`). Native gem
  binaries (sqlite3, nokogiri) are not portable across OS.
- **`<ruby-version>`** — language ABI gate. A Ruby 3.3 → 3.4 bump
  flips native ext compat for many gems.
- **`<tracer-version>`** — the rspec-tracer gem version itself.
  Cache schemas can change across tool versions; restoring an
  old-shape cache after an upgrade is a wasted restore.
- **`<gemfile-hash>`** — content hash of the project's Gemfile (or
  Gemfile.lock if committed). Manifest edits are the most common
  reason a previously-populated cache is out of date.

Pair the exact key with a `restore-keys`-style ladder where
supported (manifest hash drops first, then tool-version, then
lang-version) so a Gemfile bump still warm-starts from the closest
prior shape rather than going fully cold.

---

## CircleCI

```yaml
# .circleci/config.yml
version: 2.1

jobs:
  rspec:
    docker:
      - image: cimg/ruby:3.3.10
    steps:
      - checkout

      - run:
          name: bundle install
          command: bundle install --path vendor/bundle

      # Restore rspec_tracer_cache/ from a prior run. CircleCI's
      # `restore_cache` walks the keys in order, restoring the first
      # match. The exact key carries every invalidation input; the
      # fallback prefixes progressively widen the match.
      - restore_cache:
          keys:
            - rspec-tracer-v1-{{ arch }}-ruby-3.3.10-tracer-2.0.0-{{ checksum "Gemfile.lock" }}
            - rspec-tracer-v1-{{ arch }}-ruby-3.3.10-tracer-2.0.0-
            - rspec-tracer-v1-{{ arch }}-ruby-3.3.10-

      - run:
          name: rspec
          command: bundle exec rspec

      # Save freshly-updated rspec_tracer_cache/ back under the same
      # exact key. If the same key already has an entry, CircleCI
      # writes the new content (last-write-wins).
      - save_cache:
          key: rspec-tracer-v1-{{ arch }}-ruby-3.3.10-tracer-2.0.0-{{ checksum "Gemfile.lock" }}
          paths:
            - rspec_tracer_cache
```

**Notes:**

- `{{ arch }}` covers the OS axis on CircleCI's machine executors.
- Bump the prefix (`rspec-tracer-v1-...`) when the rspec-tracer schema
  bumps; CircleCI keys are immutable so a manual prefix bump is the
  invalidation lever.
- For matrix builds across Ruby versions, parameterize the key:
  `ruby-{{ matrix.ruby }}` instead of the literal `3.3.10`.

---

## GitLab CI

```yaml
# .gitlab-ci.yml
image: ruby:3.3.10

cache:
  # GitLab cache keys support a `files:` array + a per-file fallback
  # ladder via `key:files:`. Pair that with a literal prefix so the
  # tracer-version bump is a single string edit.
  key:
    prefix: rspec-tracer-v1-ruby-3.3.10-tracer-2.0.0
    files:
      - Gemfile.lock
  paths:
    - rspec_tracer_cache/

rspec:
  script:
    - bundle install --path vendor/bundle
    - bundle exec rspec
```

**Notes:**

- GitLab's cache is per-job by default. To share across job
  branches, set `cache:policy: pull-push` (default) and ensure the
  `key:` shape matches across the jobs that should hit the same
  cache.
- The `files:` array hashes the listed files into the key; if
  Gemfile.lock isn't committed, swap to `Gemfile` (less precise but
  stable enough for the warm-cache common case).
- For multi-Ruby matrix:
  ```yaml
  parallel:
    matrix:
      - RUBY_VERSION: ['3.1.6', '3.2.5', '3.3.10', '3.4.1']
  cache:
    key:
      prefix: rspec-tracer-v1-ruby-${RUBY_VERSION}-tracer-2.0.0
      files: [Gemfile.lock]
    paths: [rspec_tracer_cache/]
  ```

---

## Buildkite

```yaml
# .buildkite/pipeline.yml
steps:
  - label: ":rspec: rspec"
    command: |
      bundle install --path vendor/bundle
      bundle exec rspec
    plugins:
      - cache#v1.7.1:
          # Cache key composes the four invalidation inputs; the
          # fallback list is a manual restore-keys ladder.
          manifest:
            - Gemfile.lock
          path: rspec_tracer_cache
          restore: pipeline
          save: pipeline
          key: |
            v1-rspec-tracer-{{ os }}-ruby-3.3.10-tracer-2.0.0-{{ hash "Gemfile.lock" }}
          fallback_keys:
            - v1-rspec-tracer-{{ os }}-ruby-3.3.10-tracer-2.0.0-
            - v1-rspec-tracer-{{ os }}-ruby-3.3.10-
```

**Notes:**

- The `cache#v1.x` plugin (Buildkite's official plugin) provides
  S3-backed cache out of the box; configure the bucket via the
  plugin's `s3_bucket` option or the agent's `BUILDKITE_PLUGIN_CACHE_S3_BUCKET`
  env var.
- `{{ os }}` substitutes the runner OS via the plugin's template
  language; `{{ hash "Gemfile.lock" }}` produces a deterministic
  short hash.
- For matrix builds across Ruby versions, factor the version into a
  pipeline-level env var and substitute via `{{ env "RUBY_VERSION" }}`.

---

## Heroku CI

Heroku CI's `app.json` doesn't expose a built-in cache primitive
the way the other providers do, so the canonical pattern uses an S3
bucket via rspec-tracer's own remote-cache backend (the rake-task
flow rspec-tracer's README documents). The cache invalidation
inputs are the same four; the storage substrate is S3 instead of
the CI provider's built-in cache.

```json
{
  "name": "myapp",
  "environments": {
    "test": {
      "scripts": {
        "test-setup": "bundle exec rake rspec_tracer:remote_cache:download",
        "test": "bundle exec rspec",
        "test-teardown": "bundle exec rake rspec_tracer:remote_cache:upload"
      },
      "env": {
        "GIT_DEFAULT_BRANCH": "main",
        "GIT_BRANCH": "$HEROKU_TEST_RUN_BRANCH",
        "RSPEC_TRACER_REMOTE_CACHE_URI": "s3://my-bucket/rspec-tracer"
      }
    }
  }
}
```

**Notes:**

- The S3 bucket is the storage substrate; rspec-tracer's two-tier
  layout (`main/<sha>/`, `pr/<branch>/<sha>/`) provides the same
  cold/warm cycle as the platform-built-in caches above.
- `HEROKU_TEST_RUN_BRANCH` is Heroku CI's own env var; map it to
  `GIT_BRANCH` so rspec-tracer's PR-tier resolution works.
- AWS creds (`AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY`) belong
  in Heroku CI's encrypted env, not in `app.json`.
- The same pattern works on any CI provider that does NOT have a
  native cache primitive — the rspec-tracer remote-cache backend
  abstracts the substrate.

---

## Validating the cache works end-to-end

After landing one of the recipes above, verify on the next two
runs:

1. **Cold first run** — no prior cache; rspec-tracer runs every
   example; on success the cache writes back at job-end.
2. **Warm second run** — cache restores; rspec-tracer reads
   `last_run.json`, finds matching dependencies for unchanged
   examples, and emits a "skipped" terminal line for them. Look
   for the `rspec-tracer: N examples tracked · M re-run · K
   skipped (X% cached)` line in the run output.

If the warm run shows `0% cached` despite the cache restoring, one
of the invalidation inputs differs run-to-run (typically a
timestamp baked into the Gemfile hash or a runner-OS mismatch).
Run `bundle exec rspec-tracer doctor` locally with the same cache
to diagnose; the doctor's `schema:` + `cache_path:` + `git:` lines
surface the typical culprits.

---

## See also

- [`ARCHITECTURE.md`](../ARCHITECTURE.md) — the input-taxonomy +
  schema-versioning model that drives cache invalidation.
- [`.github/workflows/example-tracer-cache.yml`](../.github/workflows/example-tracer-cache.yml)
  — the GHA reference workflow these recipes translate.
- README "Configuring CI" section — the rake-task flow for projects
  that prefer rspec-tracer's own remote-cache backend over the CI
  provider's built-in cache.
