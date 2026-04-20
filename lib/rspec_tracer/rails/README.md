# Rails integration

Auto-loaded when Rails is present. Provides a sensible preset for Rails
test suites and wires Rails-specific input observers.

## Responsibilities

- Detect Rails and opt in automatically (Railtie-based).
- Subscribe to `ActiveSupport::Notifications` for template renders, I18n
  lookups, factory/fixture loads.
- Provide a preset covering the common Rails tracking surface
  (`config/locales/**/*.yml`, `db/schema.rb`, views, fixtures, factories).

## Status

Placeholder for 2.0. No Rails integration existed in 1.x; this layer is
net-new and lands in Phase 4 (sessions M4.1–M4.3). The integration
test runs against the reference Rails 7.1 app fixture from M2.3.
