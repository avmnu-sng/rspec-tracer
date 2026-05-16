# Cookbook

Recipes for common rspec-tracer setups. Each recipe is self-contained
and shows the minimum config + commands you need.

For the conceptual model see [`README.md`](README.md). For migration
from 1.x see [`UPGRADING.md`](UPGRADING.md). For internals see
[`ARCHITECTURE.md`](ARCHITECTURE.md).

## Index

1. [Add to a fresh Ruby gem](#1-add-to-a-fresh-ruby-gem)
2. [Add to an existing Rails app](#2-add-to-an-existing-rails-app)
3. [Migrate a 1.x project to 2.0](#3-migrate-a-1x-project-to-20)
4. [Configure remote cache (S3 / Local-FS / Redis)](#4-configure-remote-cache)
5. [Run with `parallel_tests`](#5-run-with-parallel_tests)
6. [Run on JRuby](#6-run-on-jruby)
7. [Track non-Ruby deps via `tracks:`](#7-track-non-ruby-deps-via-tracks)
8. [Track env-var branching](#8-track-env-var-branching)
9. [Use SQLite storage instead of JSON](#9-use-sqlite-storage-instead-of-json)
10. [Debug "why did this test re-run?"](#10-debug-why-did-this-test-re-run)
11. [Compose with Knapsack / RSpec::Retry / RSpec::Rerun](#11-compose-with-knapsack--rspecretry--rspecrerun)
12. [Write a custom storage backend](#12-write-a-custom-storage-backend)
13. [Write a custom reporter](#13-write-a-custom-reporter)

---

## 1. Add to a fresh Ruby gem

Goal: skip already-passing examples on subsequent runs.

```ruby
# Gemfile
# 2.0 is in pre-release; switch to '~> 2.0' once 2.0.0 final ships.
gem 'rspec-tracer', '= 2.0.0.pre.2', group: :test, require: false
```

```sh
bundle install
```

```ruby
# spec/spec_helper.rb (very first line)
require 'rspec_tracer'
RSpecTracer.start

# ... your existing spec_helper config below
```

```
# .gitignore
rspec_tracer.lock
rspec_tracer_cache/
rspec_tracer_coverage/
rspec_tracer_report/
```

Run the suite twice. The second run skips examples whose inputs
didn't change between runs:

```sh
bundle exec rspec       # cold; everything runs
bundle exec rspec       # warm; skips unaffected examples
```

The `rspec_tracer_report/index.html` file gives you per-example +
per-file dependency views.

---

## 2. Add to an existing Rails app

Goal: get rspec-tracer's per-example skip behavior on a Rails app
with views, locales, fixtures, schema, and per-example AR queries.

```ruby
# Gemfile (test group)
# 2.0 is in pre-release; switch to '~> 2.0' once 2.0.0 final ships.
gem 'rspec-tracer', '= 2.0.0.pre.2', group: :test, require: false
```

```ruby
# spec/rails_helper.rb (top of file)
require 'simplecov'   # if you use it; load BEFORE rspec_tracer
SimpleCov.start

require 'rspec_tracer'
RSpecTracer.start

# Existing rails_helper.rb config follows
require File.expand_path('../config/environment', __dir__)
require 'rspec/rails'
```

```ruby
# .rspec-tracer
RSpecTracer.configure do
  track_rails_defaults
end
```

`track_rails_defaults` attaches the common Rails-side declared globs
(views, locales, fixtures, factories, helpers, config, schema). For
narrower per-example schema attribution, see recipe
[#4](#4-configure-remote-cache) below.

**Trade-off worth knowing**: if your test env runs with
`config.eager_load = true` (Rails CI default), all `app/` files
load at boot and any `app/` edit triggers a whole-suite re-run. To
recover per-example precision, set `config.eager_load = false` in
`config/environments/test.rb`. See README "How it works" for the
full rationale.

### Rails engines: `lib/` always lands in the boot set

A gem-loaded engine's own `lib/` files are `require`d at gem load
time (via the Gemfile.lock cascade) and land in the boot set
**regardless of `eager_load`**. Editing any `lib/<engine_name>/...`
file re-runs every example in the engine's spec suite. This is
**safe** (never misses a dep) but **coarser** than per-example
attribution. The behavior is deliberate: it closes the
constants-lookup blind spot that pure coverage-diff tracking
misses (an example that references a constant defined in a loaded
file produces no coverage delta against that file, even though the
example depends on it).

If your engine's `lib/`-edit cycle is bottlenecked by whole-suite
re-runs and you've audited that your suite doesn't exercise the
constants-lookup pattern, opt out with:

```ruby
# .rspec-tracer
RSpecTracer.configure do
  transitive_load_tracking false
end
```

Trade-off: this restores 1.x's pure coverage-diff behavior. The
constants-lookup blind spot returns — an example that only
references a constant from a loaded file (without exercising any
of its lines) will not be tagged as depending on that file, so
editing the file may not re-run the example. Most suites are
unaffected (any line execution against the file already attributes
the dep correctly); audit yours before flipping. The 2.1
`track_class_attribution` work will close this gap more precisely.

### Sub-rspec summaries (engine + dummy-app)

If your engine fixture does sub-process rspec invocations — e.g.,
acceptance specs that `chdir` into a generated dummy app and run
a nested `rspec` — you'll see two rspec summary totals in the
same `bundle exec rspec` invocation (one from the inner sub-rspec,
one from the outer). rspec-tracer tracks the **outer** process
and is the authoritative example count for your cache; the inner
summary belongs to the dummy-app sub-process and is not visible
to the tracer.

---

## 3. Migrate a 1.x project to 2.0

Goal: zero-touch upgrade preserving every 1.x behavior + adopting
the new `track_rails_defaults` to close Rails blind spots.

```sh
bundle update rspec-tracer
bundle exec rspec       # one cold run (cache schema bumped)
bundle exec rspec       # warm again
```

The 1.x cache is refused; the first 2.0 run rebuilds it. Subsequent
runs warm-skip as before.

**1.x → 2.0 deprecated DSL** (still works, fires a one-time warn):

| 1.x                                 | 2.0 replacement                                       |
|-------------------------------------|-------------------------------------------------------|
| `reports_s3_path 's3://...'`        | `remote_cache_uri 's3://...'`                         |
| `use_local_aws true`                | `remote_cache_backend :s3, local: true`               |
| `RSPEC_TRACER_REPORTS_S3_PATH=...`  | `RSPEC_TRACER_REMOTE_CACHE_URI=...`                   |
| `RSPEC_TRACER_USE_LOCAL_AWS=true`   | Pass via `remote_cache_backend` params instead.       |

The `rake rspec_tracer:remote_cache:download` / `:upload` task
surface is unchanged. See [`UPGRADING.md`](UPGRADING.md) for the
complete migration guide.

---

## 4. Configure remote cache

Pick one backend in `.rspec-tracer`. The `rake` task surface stays
identical — only the storage substrate differs.

### S3 (preserves 1.x layout)

```ruby
# .rspec-tracer
RSpecTracer.configure do
  remote_cache_backend :s3, bucket: 'my-bucket', prefix: 'rspec-tracer'
end
```

```sh
# In CI:
GIT_DEFAULT_BRANCH=main GIT_BRANCH=$BRANCH \
AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... \
bundle exec rake rspec_tracer:remote_cache:download
bundle exec rspec
bundle exec rake rspec_tracer:remote_cache:upload
```

### LocalStack / awslocal (development)

```ruby
RSpecTracer.configure do
  remote_cache_backend :s3, bucket: 'local-bucket',
                       prefix: 'rspec-tracer', local: true
end
```

### Filesystem-backed (no S3 needed)

```ruby
RSpecTracer.configure do
  remote_cache_backend :local_fs, root: '/tmp/rspec-tracer-cache'
end
```

Useful when you have a shared NFS / EFS mount across CI workers, or
when you just want to test the upload/download flow locally without
LocalStack.

### Redis (with optional TTL + PR-branch tracking)

```ruby
RSpecTracer.configure do
  remote_cache_backend :redis,
                       url: ENV.fetch('REDIS_URL'),
                       ttl: 7 * 86_400  # 1 week per-key TTL
end
```

PR-tier uploads also write to a `<prefix>:pr_branches` Redis Set —
useful for ops dashboards (`SMEMBERS rspec-tracer:pr_branches`)
without enumerating the full key namespace.

---

## 5. Run with `parallel_tests`

`parallel_tests` works out of the box. The tracker writes per-worker
caches under `rspec_tracer_cache/parallel_tests_N/` and merges them
into the top-level cache at finalize on the elected last worker.

```sh
bundle exec parallel_rspec spec/
```

If you interrupt mid-run, delete the lock file before the next
attempt:

```sh
rm -f rspec_tracer.lock && bundle exec parallel_rspec spec/
```

The HTML / JSON / terminal reports emit ONCE at the merged top-level
location after merge completes (not per-worker — the per-worker
reports get purged at finalize alongside the per-worker cache dirs).

---

## 6. Run on JRuby

```sh
export JRUBY_OPTS="--debug -X+O"
```

In your project's `Gemfile`, add the JDBC adapter for your Rails
line (the major number tracks Rails: `~> 71.0` for Rails 7.1):

```ruby
gem 'activerecord-jdbcsqlite3-adapter', '~> 71.0', platforms: :jruby
```

`config/database.yml`'s `adapter: sqlite3` resolves to the JDBC
chain transparently.

**JRuby caveats**:
- The `:sqlite` storage backend is unavailable; rspec-tracer auto-
  falls-back to the `:json` backend with a one-time warn.
- Per-iter benchmark times are higher because every test subprocess
  pays full JVM boot. This is JVM cost, not tracer overhead.
- Rails 8.0 + JRuby is unsupported (no `~> 80.0` JDBC adapter
  upstream); pin Rails to 7.x on JRuby.

---

## 7. Track non-Ruby deps via `tracks:`

Goal: invalidate specific examples when a config file or non-Ruby
asset they read changes.

```ruby
RSpec.describe AdminController,
               tracks: { files: 'app/policies/**/*.rb' } do
  it 'gates by role' do
    # ...
  end
end
```

Now editing any `app/policies/*.rb` file re-runs only the
AdminController examples — not the entire suite.

`:files` accepts a single string glob or an array:

```ruby
tracks: { files: ['app/policies/**/*.rb', 'config/roles.yml'] }
```

**Cascade**: nested describes contribute additively; the inner
group does NOT clobber the outer:

```ruby
RSpec.describe Admin, tracks: { files: 'config/roles.yml' } do
  context 'with policy DSL', tracks: { files: 'app/policies/**/*.rb' } do
    # both globs apply to examples in this context
  end
end
```

For files **every** test depends on, use `track_files` at config
level instead — declaring per-example via `tracks:` is for narrow
attribution.

---

## 8. Track env-var branching

Goal: invalidate examples when an env var they branch on changes
between runs.

### Config-level (every example depends on the var)

```ruby
# .rspec-tracer
RSpecTracer.configure do
  track_env 'AUTH_TOKEN', 'DATABASE_URL', 'RAILS_*'
end
```

Wildcards: `'PREFIX_*'`, `'*_SUFFIX'`, bare `'*'`. Expanded against
the live ENV at config load; the persisted snapshot
(`env_snapshot.json`) carries concrete keys only.

### Per-example (only specific examples branch on it)

```ruby
RSpec.describe Auth, tracks: { env: 'JWT_SECRET' } do
  it 'verifies the token' do
    # ...
  end
end
```

Or with wildcards:

```ruby
tracks: { env: 'OAUTH_*' }
```

A missing env var is digested as the empty string. Changing the
value (or setting/unsetting) invalidates the dependent examples.

---

## 9. Use SQLite storage instead of JSON

Goal: faster cold reads on suites with > ~5,000 examples.

```ruby
# .rspec-tracer
RSpecTracer.configure do
  storage_backend :sqlite
end
```

Or as a per-run override:

```sh
RSPEC_TRACER_STORAGE=sqlite bundle exec rspec
```

The on-disk layout becomes a single `rspec_tracer.sqlite3` file
instead of the 10-file JSON directory. Both backends store the
same data; the SQLite backend avoids the per-file open overhead at
cold-read time.

**JRuby**: `:sqlite` is unsupported; the engine warns once and
falls back to `:json` automatically.

### Smaller caches with `:msgpack`

Goal: ~3.5x on-disk cache reduction (helps CI artifact size and
remote_cache upload time on suites with many examples).

```ruby
# .rspec-tracer
RSpecTracer.configure do
  storage_backend :json, serializer: :msgpack
end
```

Add `gem 'msgpack'` to your Gemfile (test group). Cache files now
end with `.msgpack.gz` instead of `.json`. If `msgpack` isn't
loadable at boot, the engine warns once and falls back to `:json`.

**Filename caveat**: despite the `.gz` suffix, payloads are raw
`Zlib::Deflate` streams (not gzip format) — `gunzip` fails on them.
The suffix is cosmetic and may change in a future major release.

### Coverage modes (rspec-tracer + SimpleCov interop)

By default, rspec-tracer enables Ruby's `lines` coverage mode only.
The `coverage_modes` DSL opts into additional Ruby `Coverage` modes
on the standalone (non-SimpleCov) path:

```ruby
# .rspec-tracer
RSpecTracer.configure do
  coverage_modes [:lines, :branches]
end
```

Allowed modes: `:lines`, `:branches`, `:methods`, `:oneshot_lines`,
`:eval`. The default is `[:lines]` (matches pre-#195 bare
`Coverage.start` behavior).

When SimpleCov is loaded and running at `RSpecTracer.start` time, the
DSL is inert — SimpleCov owns `::Coverage.start` and exposes its own
knobs (`enable_coverage :branch`, `enable_coverage_for_eval`). See
[`UPGRADING.md` § "SimpleCov branch coverage now works"](UPGRADING.md)
for the SimpleCov load-order contract.

`coverage.json` stays on the 1.x `Array<Integer|nil>` per-file shape
regardless of modes (storage-format stability). Branch / method data
is tracked by Ruby and available via `Coverage.peek_result` directly
for downstream tooling that reads it; the canonical user-facing
artifact remains lines-only.

#### Per-mode interop matrix

| Mode | Ruby support | rspec-tracer standalone | rspec-tracer + SimpleCov 0.22 |
|---|---|---|---|
| `lines` | yes | yes (default) | yes (SimpleCov default) |
| `branches` | yes | yes — `coverage_modes [:lines, :branches]` | yes — `SimpleCov.start { enable_coverage :branch }` |
| `methods` | yes | yes — `coverage_modes [:lines, :methods]` | no (SimpleCov 0.22 has no API to enable) |
| `oneshot_lines` | yes (alternative to `lines`) | yes — `coverage_modes [:oneshot_lines]` | no (no SimpleCov API) |
| `eval` | yes | yes — `coverage_modes [:lines, :eval]` | partial — SimpleCov forwards `enable_coverage_for_eval` to `Coverage.start` but `coverage/.resultset.json` strips the `(eval at /path:line)` virtual-file entries |

Validated empirically on Ruby 3.4.8 and Ruby 4.1.0dev with SimpleCov
0.22.0; check `Coverage.respond_to?(:start)`'s keyword arguments on
your Ruby version for the authoritative supported set.

---

## 10. Debug "why did this test re-run?"

Use `bundle exec rspec-tracer explain <example_id_or_substring>`:

```sh
bundle exec rspec-tracer explain 'AdminController#create'
```

Prints the example's last-run status, dependency set, and the run-
decision reason (e.g. `"Files changed: app/controllers/admin_controller.rb"`,
`"Whole-suite invalidator changed: Gemfile.lock"`,
`"Failed previously"`).

For a suite-wide breakdown, the terminal output already shows the
top-level reasons after each run:

```
rspec-tracer: 1,820 examples · 42 re-run · 1,778 skipped (97% cached)
by reason: 38 Files changed · 4 Failed previously
```

For deeper config-level debugging, `bundle exec rspec-tracer doctor`
diagnoses the boot-time state of every contract (SimpleCov load
order, schema version, remote-cache reachability, AR-schema config).

---

## 11. Compose with Knapsack / RSpec::Retry / RSpec::Rerun

These all coexist with rspec-tracer; their RSpec hooks compose with
the tracer's `Module#prepend` chain. Add the gems normally.

### Knapsack (free) — shard your suite across CI workers

```ruby
# Gemfile
gem 'knapsack'
```

```sh
KNAPSACK_TEST_FILE_PATTERN='spec/**/*_spec.rb' \
CI_NODE_TOTAL=4 CI_NODE_INDEX=$INDEX \
bundle exec rake knapsack:rspec
```

Compose: shard with knapsack, skip with rspec-tracer on each shard.
The skip decisions are per-shard since each worker has its own
cache.

### RSpec::Retry — retry flaky failures

```ruby
gem 'rspec-retry'
```

```ruby
# spec_helper.rb
require 'rspec/retry'
RSpec.configure do |config|
  config.verbose_retry = true
  config.default_retry_count = 2
end
```

rspec-tracer detects flaky examples (same inputs, different
outcomes) and refuses to skip them on subsequent runs even after
retry succeeds — so the next run always re-investigates the flake.

### RSpec::Rerun — re-run only failures

```ruby
gem 'rspec-rerun'
```

```sh
bundle exec rake rspec-rerun:spec
```

Composes cleanly. rspec-tracer's per-example tracking proceeds
through the rerun chain.

---

## 12. Write a custom storage backend

Implement `RSpecTracer::Storage::Backend`'s 5-method protocol:

```ruby
class MyBackend
  def initialize(connection_string:)
    @conn = open_my_storage(connection_string)
  end

  def load_graph(schema_version:)
    # Return RSpecTracer::Storage::Snapshot or nil.
    # Nil = no cache OR schema mismatch (treat as cold run).
    # Never raise on corruption — log + return nil.
  end

  def save_graph(snapshot, schema_version:)
    # Persist the snapshot atomically.
  end

  def last_run_id
    # Return the most-recent run_id, or nil.
  end

  def transactional_save(&block)
    # Yield with single-writer semantics; commit on clean exit;
    # roll back on raise.
    yield
  end

  def clear!
    # Remove everything this backend owns.
  end
end
```

Register:

```ruby
RSpecTracer.configure do
  storage_backend MyBackend.new(connection_string: ENV['MY_DB_URL'])
end
```

The protocol contract + invariants live in
[`ARCHITECTURE.md`](ARCHITECTURE.md). The shared-examples group at
`spec/contracts/storage_backend.rb` exercises every requirement —
add your backend's spec to it.

---

## 13. Write a custom reporter

Subclass `RSpecTracer::Reporters::Base`:

```ruby
class SlackReporter < RSpecTracer::Reporters::Base
  def generate
    return if no_op?

    payload = {
      examples: snapshot.all_examples.size,
      re_run: snapshot.re_run_examples.size,
      skipped: snapshot.skipped_examples.size,
      run_time: run_metadata[:run_time]
    }
    HTTP.post(options[:webhook], json: payload)
  end
end
```

Register with reporter-specific opts:

```ruby
RSpecTracer.configure do
  add_reporter SlackReporter, webhook: ENV.fetch('SLACK_WEBHOOK')
end
```

Errors inside `generate` are caught by the Registry's per-reporter
rescue + warn — a buggy custom reporter never breaks the test
suite. Same graceful-degradation contract as Storage backends.

---

## Got a recipe to add?

Open a [Discussion](https://github.com/avmnu-sng/rspec-tracer/discussions/categories/ideas)
with the scenario + minimum config; if it's a common pattern it'll
land here in a future docs pass.
