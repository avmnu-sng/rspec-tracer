# Rails integration

Loaded by `require 'rspec_tracer/rails'`. Exposes the Rails preset and
wires a Railtie that integrates with the Rails lifecycle when Rails is
present in the process.

## Surface

- **`RSpecTracer::Rails::Preset`** - closed-enum glob set covering the
  Coverage-invisible Rails surface (views, helpers, locales, config
  YAML, schema, factories, fixtures). Opt in via `track_rails_defaults`
  in `.rspec-tracer`; opt out per category via
  `track_rails_defaults except: [:views, :locales]`.
- **`RSpecTracer::Rails::Railtie`** - only loaded when
  `defined?(::Rails::Railtie)`. Registers a single `rspec_tracer.setup`
  initializer that logs a confirmation line when Rails boots.

## Detection

`RSpecTracer.rails?` returns true when `::Rails::VERSION` is defined at
the time `RSpecTracer.start` runs. The flag is computed once during
`initial_setup`; subsequent Rails loads do not flip it.

## Zero-cost when Rails is absent

`require 'rspec_tracer/rails'` loads Preset unconditionally and skips
the Railtie via `defined?(::Rails::Railtie)`. A pure-Ruby suite that
accidentally requires the file never pays for Rails-specific code.

## Phase 4 scope split

- **M4.1** (this file, shipped): preset + detection + Railtie scaffold.
- **M4.2**: ActionView / I18n / schema / factory / fixture notification
  subscribers plug into the Railtie.
- **M4.3**: integration test against the reference Rails app
  (`spec/fixtures/rails_app/`) covering the full "change X -> Y re-runs"
  behavior matrix.
