# How the `tracks:` DSL cascades

The per-example `tracks: { files:, env: }` metadata DSL declares
extra inputs the tracker can't auto-observe. This doc walks how
nested describe groups combine those declarations and why we ship a
custom walker instead of relying on RSpec's built-in metadata
inheritance.

## The DSL surface (recap)

```ruby
RSpec.describe AdminController,
               tracks: { files: 'app/policies/**/*.rb', env: 'ROLE_CONFIG' } do
  context 'with feature flag', tracks: { env: 'FEATURE_X' } do
    it 'gates by role' do
      # ...
    end
  end
end
```

The example inside the inner `context` should pick up:

- `:files` from the outer describe (`app/policies/**/*.rb`)
- `:env` from BOTH groups (`ROLE_CONFIG` + `FEATURE_X`, unioned)

That's the cascade contract: nested groups contribute additively;
inner groups never clobber outer ones on shared keys.

## Why we don't use RSpec's built-in metadata inheritance

RSpec already cascades metadata from describe → context → example.
But its built-in cascade is **replace-on-conflict, not union**.

For scalar metadata (`type: :request`, `:slow`, etc.) replace-on-
conflict is the right choice. For our hash-valued `tracks:`, replace
would silently drop the outer's `:env` value when an inner group
re-declares `:env`:

```ruby
# With RSpec's built-in cascade (HYPOTHETICAL — NOT what we do):
describe Foo, tracks: { env: 'A' } do
  context 'inner', tracks: { env: 'B' } do
    it 'silently loses A' do      # would track only :env => 'B'
    end
  end
end
```

That's a silent-degradation surprise. The user wrote `tracks: { env:
'A' }` on the outer expecting it to apply; the inner group
unintentionally removed it.

## Our walker: union explicitly

`RSpecTracer::RSpec::Metadata.tracks_for(example)` walks the example
group ancestor chain bottom-up and unions the `:files` + `:env`
values:

```ruby
# Pseudocode of the walker shape (see lib/rspec_tracer/rspec/metadata.rb)
def self.tracks_for(example)
  files = Set.new
  envs  = Set.new
  ancestor = example.example_group
  while ancestor
    tracks = ancestor.metadata[:tracks] || {}
    files.merge(Array(tracks[:files]))
    envs.merge(Array(tracks[:env]))
    ancestor = ancestor.superclass
  end
  { files: files, env: envs }
end
```

Walking bottom-up + accumulating into Sets means:
- Outer + inner contributions both land.
- No duplicate-glob processing if both groups happen to declare the
  same path.
- Order doesn't matter (Sets are unordered) — the dependency graph
  ultimately stores file digests, not ordering.

The walker's actual implementation is at
[`lib/rspec_tracer/rspec/metadata.rb`](../../lib/rspec_tracer/rspec/metadata.rb)
with unit specs at `spec/rspec/metadata_inheritance_spec.rb` covering
the cascade interaction (single group / nested / cousin groups /
shared examples).

## How the walker output flows into the engine

1. **At per-example start time**: the `RunnerHook`'s
   `example_started` callback calls `tracks_for(example)` to get the
   `{files:, env:}` Set pair.
2. **The Set pair gets passed to** `Engine#register_tracks` which:
   - Resolves each `:files` glob via `Dir.glob(glob, FNM_PATHNAME |
     FNM_EXTGLOB)`, memoizing per-glob results so the second
     example with the same glob doesn't re-walk the filesystem.
   - For each matched file, registers a `:declared`-kind Input on
     the example's dep set.
   - For each `:env` name, applies wildcard expansion against the
     live ENV (`Tracker::EnvMatcher`) and adds the concrete keys
     to the example's tracked-env set.
3. **At finalize**: env values get digested into
   `env_snapshot.json`. Files roll into the existing `dependency.json`
   / `all_files.json` / `reverse_dependency.json` shape — they're
   not stored separately by source.

## Wildcard env expansion

`tracks: { env: 'PREFIX_*' }` expands at register-tracks time, not
at digest time. Implication: only env vars that **existed at the
time the example registered tracks** get attribution.

```ruby
ENV['ROLE_CONFIG_ADMIN'] = 'a'
ENV['ROLE_CONFIG_USER']  = 'b'

RSpec.describe Auth, tracks: { env: 'ROLE_CONFIG_*' } do
  it 'attributes both' do
    # tracked: ['ROLE_CONFIG_ADMIN', 'ROLE_CONFIG_USER']
  end
end
```

If `ROLE_CONFIG_GUEST=c` gets set later in the same run (e.g. in a
`before` block), it does NOT get retroactively attributed to the
example — the wildcard expansion already concluded.

The persisted `env_snapshot.json` only carries concrete keys, never
the wildcard pattern itself. This means re-defining a wildcard
between runs simply updates which concrete keys the next snapshot
covers; old keys (no longer matching) get dropped.

Pattern grammar (rejected at config-load time with `ArgumentError`):

- Multi-segment / embedded wildcards: `'A_*_B'`
- Multiple wildcards: `'A_*_B_*'`
- Character classes / negation / glob `?` / `\\`: `'A_[X]'`,
  `'A_!B'`, `'A_?'`

The full grammar lives in `lib/rspec_tracer/tracker/env_matcher.rb`.

## Cascade with shared examples

```ruby
RSpec.shared_examples 'role-gated', tracks: { files: 'app/policies/**/*.rb' } do
  it 'gates by role' do
  end
end

RSpec.describe AdminController, tracks: { env: 'ADMIN_TOKEN' } do
  it_behaves_like 'role-gated'   # picks up BOTH :files + :env
end
```

Shared example groups participate in the ancestor walk just like any
other group. Both contributions union.

## What the `tracks:` DSL does NOT do

- **Doesn't bypass `track_files` precedence.** When both a per-
  example `tracks: { files: 'X' }` AND a config-level `track_files
  'X'` declare the same file, the declared-glob attribution wins
  (deterministic; see ARCHITECTURE.md "Input taxonomy" → "declared
  takes precedence" rule).
- **Doesn't replace `track_env` for the global case.** Use
  `track_env` for env vars **every** test depends on; use `tracks: {
  env: ... }` for env vars only specific examples branch on.
- **Doesn't observe metadata changes mid-run.** The walker runs at
  example-start time; modifying `metadata[:tracks]` after that
  doesn't affect attribution.

## Debugging cascade

`bin/rspec-tracer explain <example_id>` shows the resolved per-
example deps including `:tracks:`-attributed files and env names.
If a cascade isn't behaving as expected, that's the fastest way to
see what the walker actually unioned.
