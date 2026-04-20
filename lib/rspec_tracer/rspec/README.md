# RSpec integration

Glue between the tracker engine and RSpec's runner lifecycle.

## Responsibilities

- Install boot-time hooks (`before :suite`, `after :suite`).
- Install per-example hooks (`before(:each)`, `after(:each)`).
- Apply the example filter — tell RSpec which examples to skip based on
  the tracker's `affected_examples` set.
- Bridge `parallel_tests` — each process holds its own tracker instance;
  results merge at finalize.
- Surface the per-example metadata DSL:

  ```ruby
  describe "foo", tracks: { files: ['app/views/foo/**/*'], env: ['API_KEY'] } do
    # ...
  end
  ```

## Status

Placeholder for 2.0. Legacy RSpec glue lives in
`lib/rspec_tracer/rspec_reporter.rb` and `rspec_runner.rb` and migrates
here during Phase 5 (sessions M5.1, M5.2).
