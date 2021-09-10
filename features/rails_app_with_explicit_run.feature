@rails-app @simplecov @explicit-run @disable-bundler
Feature: Rails App with Explicit Run

  Adding rspec-tracer with simplecov should generate tracer reports and the
  coverage report as well. It should skip some examples when cache found and no
  dependency change is detected.

  Scenario: Rails App with Explicit Run
    Given I am working on the project "rails_app"
    And I use "with_simplecov.rb" as spec helper
    When I run specs using "rspec spec"
    Then The RSpecTracer should print the information
      """
        Started RSpec tracer
        Starting Rails
        RSpec tracer is running 10 examples (actual: 10, skipped: 0)
        does not enroll (No cache) (FAILED - 1)
        enrolls student (No cache)
        does not set name (No cache)
        sets name (No cache)
        does not set email (No cache) (PENDING: Temporarily skipped with xcontext)
        sets email (No cache)
        does not set mobile (No cache)
        sets mobile (No cache)
        does not enroll (No cache)
        enroll student (No cache)
        10 examples, 1 failure, 1 pending
        RSpec tracer is generating reports
        SimpleCov will now generate coverage report (<3 RSpec tracer)
      """
    And The RSpecTracer report should have been generated
    And The last run report should have correct details
      """
      {
        "run_id": "6654a84c672a717904112cef7503d7a1",
        "actual_count": 10,
        "example_count": 10,
        "skipped_examples": 0,
        "failed_examples": 1,
        "pending_examples": 1
      }
      """
    And The all examples report should have correct details
    And The all files report should have correct details
      | file_name                     | file_digest                       |
      | /spec/spec_helper.rb          | 3e13379c8b6bce988973c67683d487e1  |
      | /spec/course_spec.rb          | 9413c94a334da3ed6ddf05b84e29147f  |
      | /spec/student_spec.rb         | 9da1f787f35b6af3e980205e13e9635a  |
      | /app/models/course.rb         | d70df28269ceb244b4a3620644990ffd  |
      | /app/models/student.rb        | 831c0dc99ff5690f98eb92af131931dd  |
    And The failed example report should have correct details
    And The pending example report should have correct details
    And The dependency report should have correct details
    And The reverse dependency report should have correct details
    And The JSON coverage report should have been generated for "RSpec"
    And The coverage percent stat is "71 / 72 LOC (98.61%) covered"
    And The JSON coverage report should have correct coverage for "RSpec"
    Given I want to explicitly run all the tests
    When I run `bundle exec rspec spec`
    Then The RSpecTracer should print the information
      """
        Started RSpec tracer
        Starting Rails
        RSpec tracer is running 10 examples (actual: 10, skipped: 0)
        does not enroll (Explicit run) (FAILED - 1)
        enrolls student (Explicit run)
        does not set name (Explicit run)
        sets name (Explicit run)
        does not set email (Explicit run) (PENDING: Temporarily skipped with xcontext)
        sets email (Explicit run)
        does not set mobile (Explicit run)
        sets mobile (Explicit run)
        does not enroll (Explicit run)
        enroll student (Explicit run)
        10 examples, 1 failure, 1 pending
        RSpec tracer is generating reports
        SimpleCov will now generate coverage report (<3 RSpec tracer)
      """
    And The RSpecTracer report should have been generated
    And The last run report should have correct details
      """
      {
        "run_id": "6654a84c672a717904112cef7503d7a1",
        "actual_count": 10,
        "example_count": 10,
        "skipped_examples": 0,
        "failed_examples": 1,
        "pending_examples": 1
      }
      """
    And The all examples report should have correct details
    And The all files report should have correct details
      | file_name                     | file_digest                       |
      | /spec/spec_helper.rb          | 3e13379c8b6bce988973c67683d487e1  |
      | /spec/course_spec.rb          | 9413c94a334da3ed6ddf05b84e29147f  |
      | /spec/student_spec.rb         | 9da1f787f35b6af3e980205e13e9635a  |
      | /app/models/course.rb         | d70df28269ceb244b4a3620644990ffd  |
      | /app/models/student.rb        | 831c0dc99ff5690f98eb92af131931dd  |
    And The failed example report should have correct details
    And The pending example report should have correct details
    And The dependency report should have correct details
    And The reverse dependency report should have correct details
    And The JSON coverage report should have been generated for "RSpec"
    And The coverage percent stat is "71 / 72 LOC (98.61%) covered"
    And The JSON coverage report should have correct coverage for "RSpec"
    Given I reset explicit run
    When I run `bundle exec rspec spec`
    Then The RSpecTracer should print the information
      """
        Started RSpec tracer
        Starting Rails
        RSpec tracer is running 2 examples (actual: 10, skipped: 8)
        does not enroll (Failed previously) (FAILED - 1)
        does not set email (Pending previously) (PENDING: Temporarily skipped with xcontext)
        2 examples, 1 failure, 1 pending
        RSpec tracer is generating reports
        SimpleCov will now generate coverage report (<3 RSpec tracer)
      """
    And The RSpecTracer report should have been generated
    And The last run report should have correct details
      """
      {
        "run_id": "6654a84c672a717904112cef7503d7a1",
        "actual_count": 10,
        "example_count": 2,
        "skipped_examples": 8,
        "failed_examples": 1,
        "pending_examples": 1
      }
      """
    And The all examples report should have correct details
    And The all files report should have correct details
      | file_name                     | file_digest                       |
      | /spec/spec_helper.rb          | 3e13379c8b6bce988973c67683d487e1  |
      | /spec/course_spec.rb          | 9413c94a334da3ed6ddf05b84e29147f  |
      | /spec/student_spec.rb         | 9da1f787f35b6af3e980205e13e9635a  |
      | /app/models/course.rb         | d70df28269ceb244b4a3620644990ffd  |
      | /app/models/student.rb        | 831c0dc99ff5690f98eb92af131931dd  |
    And The failed example report should have correct details
    And The pending example report should have correct details
    And The dependency report should have correct details
    And The reverse dependency report should have correct details
    And The JSON coverage report should have been generated for "RSpec"
    And The coverage percent stat is "71 / 72 LOC (98.61%) covered"
    And The JSON coverage report should have correct coverage for "RSpec"
