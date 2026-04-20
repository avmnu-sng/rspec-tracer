# Tracker

Core engine for input identification. A test is a pure function of its
inputs; this layer identifies every input and hashes it.

## Responsibilities

- Observe Ruby-executed source via `Coverage`.
- Intercept file I/O (`File`, `IO`, `YAML`, `JSON`, `Kernel`).
- Subscribe to framework notifications (`ActiveSupport::Notifications`).
- Evaluate user-declared globs.
- Track whole-suite invalidators (`Gemfile.lock`, `.ruby-version`, config,
  gem version).
- Build the dependency graph and expose `affected_examples` to the
  filter.

## Public protocol

```ruby
module RSpecTracer::Tracker
  def setup(configuration:); end
  def start_example(example_id); end
  def stop_example(example_id); end
  def affected_examples(all_example_ids); end
  def finalize; end
end
```

Each input type has exactly one observation mechanism. Declared globs
take precedence over auto-interception for overlapping files.

## Status

Placeholder for 2.0. Legacy 1.x tracking logic lives in
`lib/rspec_tracer/` top-level files (`runner.rb`, `rspec_reporter.rb`,
`ruby_coverage.rb`, `cache.rb`) and migrates here during Phase 3.
