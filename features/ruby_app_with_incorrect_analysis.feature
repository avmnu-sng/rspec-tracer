@ruby-app @simplecov @incorrect-analysis @disable-bundler
Feature: Ruby App with Incorrect Analysis

  Adding rspec-tracer with simplecov should generate tracer reports and the
  coverage report as well. It should skip some examples when cache found and no
  dependency change is detected.

  Scenario: Ruby App with Incorrect Analysis
    Given I am working on the project "calculator_2_app"
    When I cd to "project"
    And I run specs using "rspec spec"
    Then The RSpecTracer should print the information
      """
        Started RSpec tracer
        RSpec tracer is running 15 examples (actual: 15, skipped: 0)
        example at ./spec/calculator_spec.rb:13 (No cache)
        performs subtraction (No cache)
        multiplies -1 and -8 to 8 (No cache)
        multiplies 1 and 2 to -2 (No cache) (FAILED - 1)
        multiplies 5 and 7 to 35 (No cache)
        multiplies 10 and 10 to 100 (No cache)
        multiplies 10 and 0 to 0 (No cache)
      """
    And The RSpecTracer should print "example at ./spec/calculator_spec.rb:13 (No cache)" example 5 times
    And The RSpecTracer should print "performs subtraction (No cache)" example 5 times
    And The RSpecTracer report should have been generated
    And The last run report should have correct details
      """
      {
        "run_id": "35194a37e68446e9d6960c46e717fd44",
        "actual_count": 15,
        "example_count": 15,
        "skipped_examples": 0,
        "failed_examples": 1,
        "pending_examples": 0
      }
      """
    And The all examples report should have correct details
    And The all files report should have correct details
      | file_name                 | file_digest                       |
      | /spec/spec_helper.rb      | 4f20a4832e5ca0e26d1ffe5a4a766a1f  |
      | /spec/calculator_spec.rb  | 6b72931a56345d552dd5ac1fd60909f3  |
      | /app/calculator.rb        | a3d17fca6ecabbbe108281e7847a24ee  |
    And The failed example report should have correct details
    And The pending example report should have correct details
    And The dependency report should have correct details
    And The reverse dependency report should have correct details
    And The JSON coverage report should have been generated for "RSpec"
    And The coverage percent stat is "5 / 5 LOC (100.0%) covered"
    And The JSON coverage report should have correct coverage for "RSpec"
    And The RSpecTracer should print the duplicate examples report
      """
        ================================================================================
           IMPORTANT NOTICE -- RSPEC TRACER COULD NOT IDENTIFY SOME EXAMPLES UNIQUELY
        ================================================================================
        RSpec tracer could not uniquely identify the following 10 examples:
          - Example ID: eabd51a899db4f64d5839afe96004f03 (5 examples)
            * Calculator#add (spec/calculator_spec.rb:13)
            * Calculator#add (spec/calculator_spec.rb:13)
            * Calculator#add (spec/calculator_spec.rb:13)
            * Calculator#add (spec/calculator_spec.rb:13)
            * Calculator#add (spec/calculator_spec.rb:13)
          - Example ID: 72171b502c5a42b9aa133f165cf09ec2 (5 examples)
            * Calculator#sub performs subtraction (spec/calculator_spec.rb:24)
            * Calculator#sub performs subtraction (spec/calculator_spec.rb:24)
            * Calculator#sub performs subtraction (spec/calculator_spec.rb:24)
            * Calculator#sub performs subtraction (spec/calculator_spec.rb:24)
            * Calculator#sub performs subtraction (spec/calculator_spec.rb:24)
      """
    When I run `bundle exec rspec spec`
    Then The RSpecTracer should print the information
      """
        Started RSpec tracer
        RSpec tracer is running 11 examples (actual: 15, skipped: 4)
        example at ./spec/calculator_spec.rb:13 (No cache)
        performs subtraction (No cache)
        multiplies 1 and 2 to -2 (Failed previously) (FAILED - 1)
      """
    And The RSpecTracer should print "example at ./spec/calculator_spec.rb:13 (No cache)" example 5 times
    And The RSpecTracer should print "performs subtraction (No cache)" example 5 times
    And The RSpecTracer report should have been generated
    And The last run report should have correct details
      """
      {
        "run_id": "35194a37e68446e9d6960c46e717fd44",
        "actual_count": 15,
        "example_count": 11,
        "skipped_examples": 4,
        "failed_examples": 1,
        "pending_examples": 0
      }
      """
    And The all examples report should have correct details
    And The all files report should have correct details
      | file_name                 | file_digest                       |
      | /spec/spec_helper.rb      | 4f20a4832e5ca0e26d1ffe5a4a766a1f  |
      | /spec/calculator_spec.rb  | 6b72931a56345d552dd5ac1fd60909f3  |
      | /app/calculator.rb        | a3d17fca6ecabbbe108281e7847a24ee  |
    And The failed example report should have correct details
    And The pending example report should have correct details
    And The dependency report should have correct details
    And The reverse dependency report should have correct details
    And The JSON coverage report should have been generated for "RSpec"
    And The coverage percent stat is "5 / 5 LOC (100.0%) covered"
    And The JSON coverage report should have correct coverage for "RSpec"
    And The RSpecTracer should print the duplicate examples report
      """
        ================================================================================
           IMPORTANT NOTICE -- RSPEC TRACER COULD NOT IDENTIFY SOME EXAMPLES UNIQUELY
        ================================================================================
        RSpec tracer could not uniquely identify the following 10 examples:
          - Example ID: eabd51a899db4f64d5839afe96004f03 (5 examples)
            * Calculator#add (spec/calculator_spec.rb:13)
            * Calculator#add (spec/calculator_spec.rb:13)
            * Calculator#add (spec/calculator_spec.rb:13)
            * Calculator#add (spec/calculator_spec.rb:13)
            * Calculator#add (spec/calculator_spec.rb:13)
          - Example ID: 72171b502c5a42b9aa133f165cf09ec2 (5 examples)
            * Calculator#sub performs subtraction (spec/calculator_spec.rb:24)
            * Calculator#sub performs subtraction (spec/calculator_spec.rb:24)
            * Calculator#sub performs subtraction (spec/calculator_spec.rb:24)
            * Calculator#sub performs subtraction (spec/calculator_spec.rb:24)
            * Calculator#sub performs subtraction (spec/calculator_spec.rb:24)
      """
