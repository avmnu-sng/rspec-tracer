@ruby-app @simplecov @no-examples @disable-bundler
Feature: Ruby App with no examples to run

  Adding rspec-tracer with simplecov should generate tracer reports and the
  coverage report as well. It should skip some examples when cache found and no
  dependency change is detected.

  Scenario: Ruby App with no examples to run
    Given I am working on the project "calculator_app"
    When I cd to "project"
    And I run specs using "rspec spec"
    Then The RSpecTracer should print the information
      """
        Started RSpec tracer
        RSpec tracer is running 10 examples (actual: 10, skipped: 0)
        adds 1 and 2 to 3 (No cache)
        adds 0 and 0 to 0 (No cache)
        adds 5 and 32 to 37 (No cache)
        adds -1 and -8 to -9 (No cache)
        adds 10 and -10 to 0 (No cache)
        subs 2 from 1 to -1 (No cache)
        subs 0 from 10 to 10 (No cache)
        subs 5 from 37 to 32 (No cache)
        subs -8 from -1 to 7 (No cache)
        subs 10 from 10 to 0 (No cache)
        SimpleCov will now generate coverage report (<3 RSpec tracer)
      """
    And The RSpecTracer report should have been generated
    And The last run report should have correct details
      """
      {
        "run_id": "ac50ff82ef0e8c97f7142ae07483d81d",
        "actual_count": 10,
        "example_count": 10,
        "skipped_examples": 0,
        "failed_examples": 0,
        "pending_examples": 0
      }
      """
    And The all examples report should have correct details
    And The all files report should have correct details
      | file_name                 | file_digest                       |
      | /spec/spec_helper.rb      | 4f20a4832e5ca0e26d1ffe5a4a766a1f  |
      | /spec/calculator_spec.rb  | 06040fb7571aedbef579b92954ab1dbb  |
      | /app/calculator.rb        | afb5e72a5e05c1ce77e3bac20bfac76d  |
    And The JSON coverage report should have been generated for "RSpec"
    And The coverage percent stat is "4 / 4 LOC (100.0%) covered"
    When I run `bundle exec rspec spec`
    Then The RSpecTracer should print the information
      """
        Started RSpec tracer
        RSpec tracer is running 0 examples (actual: 10, skipped: 10)
        RSpec tracer is generating reports
        SimpleCov will now generate coverage report (<3 RSpec tracer)
      """
    And The RSpecTracer report should have been generated
    And The last run report should have correct details
      """
      {
        "run_id": "ac50ff82ef0e8c97f7142ae07483d81d",
        "actual_count": 10,
        "example_count": 0,
        "skipped_examples": 10,
        "failed_examples": 0,
        "pending_examples": 0
      }
      """
    And The all examples report should have correct details
    And The all files report should have correct details
      | file_name                 | file_digest                       |
      | /spec/spec_helper.rb      | 4f20a4832e5ca0e26d1ffe5a4a766a1f  |
      | /spec/calculator_spec.rb  | 06040fb7571aedbef579b92954ab1dbb  |
      | /app/calculator.rb        | afb5e72a5e05c1ce77e3bac20bfac76d  |
    And The JSON coverage report should have been generated for "RSpec"
    And The coverage percent stat is "4 / 4 LOC (100.0%) covered"
    When I run `bundle exec rspec spec --only-failures`
    Then The RSpecTracer should print the information
      """
        Started RSpec tracer
        All examples were filtered out
        Skipped reports generation since all examples were filtered out
        SimpleCov will now generate coverage report (<3 RSpec tracer)
      """
    And The JSON coverage report should have been generated for "RSpec"
    And The coverage percent stat is "4 / 4 LOC (100.0%) covered"
