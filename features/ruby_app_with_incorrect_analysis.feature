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
    And The RSpecTracer should forbid using the tool
    And The RSpecTracer should print the duplicate examples report
      """
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
