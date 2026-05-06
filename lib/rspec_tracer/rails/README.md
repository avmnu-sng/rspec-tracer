# Rails integration

Loaded by `require 'rspec_tracer/rails'`. Exposes the Rails preset, the
Rails-side observer family, and a Railtie that integrates with the Rails
lifecycle when Rails is present in the process.

## Surface

- **`RSpecTracer::Rails::Preset`** - closed-enum glob set covering the
  Coverage-invisible Rails surface (views, helpers, locales, config
  YAML, schema, factories, fixtures). Opt in via `track_rails_defaults`
  in `.rspec-tracer`; opt out per category via
  `track_rails_defaults except: [:views, :locales]`.
- **`RSpecTracer::Rails::Railtie`** - only loaded when
  `defined?(::Rails::Railtie)`. Registers a single `rspec_tracer.setup`
  initializer that logs a confirmation line when Rails boots.
- **`RSpecTracer::Rails::Notifications`** - ActiveSupport::Notifications
  observer for the render_template / render_partial / render_collection
  events (ActionView) plus an opt-in sql.active_record subscriber for
  narrow schema attribution. Installed by `Engine.setup` when
  `RSpecTracer.rails?` is true. Emits `:template` Inputs for observed
  template renders and `:notification` Inputs for schema files on the
  first AR query per example.
- **`RSpecTracer::Rails::I18nTracking`** - prepends onto
  `::I18n::Backend::Base#load_translations` so every I18n backend
  (including custom Redis/DB/Chain backends that bypass
  `YAML.load_file`) emits `:notification` Inputs for the translation
  files it loads.

## Detection

`RSpecTracer.rails?` returns true when `::Rails::VERSION` is defined at
the time `RSpecTracer.start` runs. The flag is computed once during
`initial_setup`; subsequent Rails loads do not flip it.

## Zero-cost when Rails is absent

`require 'rspec_tracer/rails'` loads Preset unconditionally and skips
the Railtie via `defined?(::Rails::Railtie)`. Notifications and
I18nTracking are required lazily by `Engine.setup` only when
`RSpecTracer.rails?` is truthy. A pure-Ruby suite that accidentally
requires the file never pays for Rails-specific code.

## Narrow schema attribution (opt-in)

By default, `track_rails_defaults` attaches `db/schema.rb` and
`db/structure.sql` to every example via the Preset's `:schema`
declared-glob - a conservative whole-suite signal. Teams that want
schema changes to re-run only examples that actually touched AR can
opt into an `sql.active_record` subscriber:

```ruby
RSpecTracer.configure do
  track_rails_defaults except: [:schema]
  track_ar_schema_notifications
end
```

On the first `sql.active_record` event inside an example, the
subscriber emits `:notification` Inputs for `db/schema.rb` and
`db/structure.sql` if they exist under the project root, then
short-circuits for the remainder of that example. A non-DB-touching
example never sees the schema inputs and is not re-run on schema edits.

Leaving `:schema` in `track_rails_defaults` while also enabling the
subscriber is a no-op in terms of the re-run set - declared-glob
dominates at graph registration.

## Components

- **Preset + detection + Railtie scaffold.**
- **Notifications + I18nTracking observers**, the
  `track_ar_schema_notifications` opt-in DSL, and `Engine.setup`
  wiring. Factory and fixture coverage ride the existing
  `LoadedFilesTracker` / `YAML.load_file` hook surface.
- **Integration coverage** against the reference Rails app
  (`spec/fixtures/rails_app/`) verifying the full "change X -> Y
  re-runs" behavior matrix.
