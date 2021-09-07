@ruby-app @no-simplecov @test-suite @disable-bundler
Feature: Ruby App with Test Suite ID

  Adding rspec-tracer without simplecov should generate tracer reports and the
  coverage report as well. It should skip some examples when cache found and no
  dependency change is detected.

  Scenario: Ruby App with Test Suite ID
    Given I am working on the project "ruby_app"
    And I use "without_simplecov.rb" as spec helper
    And I use test suite id 1
    When I run specs using "rspec spec/course_spec.rb"
    Then The RSpecTracer should print the information
      """
        Started RSpec tracer
        RSpec tracer is running 2 examples (actual: 2, skipped: 0)
        does not enroll (No cache) (FAILED - 1)
        enrolls student (No cache)
        2 examples, 1 failure
        RSpec tracer is generating reports
      """
    And The RSpecTracer report should have been generated
    And The last run report should have correct details
      """
      {
        "run_id": "9badef37e6a3dd45e4d0342956371b73",
        "actual_count": 2,
        "example_count": 2,
        "skipped_examples": 0,
        "failed_examples": 1,
        "pending_examples": 0
      }
      """
    And The all examples report should have correct details
    And The all files report should have correct details
      | file_name             | file_digest                       |
      | /spec/spec_helper.rb  | 23dbc48fca7c1ef0cc63cd04f76977f8  |
      | /spec/course_spec.rb  | 7564705d731dd1521626cc08baaca4ee  |
      | /app/course.rb        | d70df28269ceb244b4a3620644990ffd  |
      | /app/student.rb       | 831c0dc99ff5690f98eb92af131931dd  |
    And The dependency report should have correct details
    And The reverse dependency report should have correct details
    And The JSON coverage report should have been generated for "RSpecTracer"
    And The coverage percent stat is "27 / 41 LOC (65.85%) covered"
    And The JSON coverage report should have correct coverage for "RSpecTracer"
    Given I use test suite id 2
    When I run `bundle exec rspec spec/student_spec.rb`
    Then The RSpecTracer should print the information
      """
        Started RSpec tracer
        RSpec tracer is running 8 examples (actual: 8, skipped: 0)
        does not set name (No cache)
        sets name (No cache)
        does not set email (No cache) (PENDING: Temporarily skipped with xcontext)
        sets email (No cache)
        does not set mobile (No cache)
        sets mobile (No cache)
        does not enroll (No cache)
        enroll student (No cache) (FAILED - 1)
        8 examples, 1 failure, 1 pending
        RSpec tracer is generating reports
      """
    And The RSpecTracer report should have been generated
    And The last run report should have correct details
      """
      {
        "run_id": "2c48486d4513ef0eeee4e7ab8c284419",
        "actual_count": 8,
        "example_count": 8,
        "skipped_examples": 0,
        "failed_examples": 1,
        "pending_examples": 1
      }
      """
    And The all examples report should have correct details
    And The all files report should have correct details
      | file_name             | file_digest                       |
      | /spec/spec_helper.rb  | 23dbc48fca7c1ef0cc63cd04f76977f8  |
      | /spec/student_spec.rb | 822cf79c51add2d042df1e4a46ec98be  |
      | /app/student.rb       | 831c0dc99ff5690f98eb92af131931dd  |
    And The dependency report should have correct details
    And The reverse dependency report should have correct details
    And The JSON coverage report should have been generated for "RSpecTracer"
    And The coverage percent stat is "17 / 41 LOC (41.46%) covered"
    And The JSON coverage report should have correct coverage for "RSpecTracer"
    Given I use test suite id 1
    When I run `bundle exec rspec spec/course_spec.rb`
    Then The RSpecTracer should print the information
      """
        Started RSpec tracer
        RSpec tracer is running 1 examples (actual: 2, skipped: 1)
        does not enroll (Failed previously) (FAILED - 1)
        1 example, 1 failure
        RSpec tracer is generating reports
      """
    And The RSpecTracer report should have been generated
    And The last run report should have correct details
      """
      {
        "run_id": "9badef37e6a3dd45e4d0342956371b73",
        "actual_count": 2,
        "example_count": 1,
        "skipped_examples": 1,
        "failed_examples": 1,
        "pending_examples": 0
      }
      """
    And The all examples report should have correct details
    And The all files report should have correct details
      | file_name             | file_digest                       |
      | /spec/spec_helper.rb  | 23dbc48fca7c1ef0cc63cd04f76977f8  |
      | /spec/course_spec.rb  | 7564705d731dd1521626cc08baaca4ee  |
      | /app/course.rb        | d70df28269ceb244b4a3620644990ffd  |
      | /app/student.rb       | 831c0dc99ff5690f98eb92af131931dd  |
    And The dependency report should have correct details
    And The reverse dependency report should have correct details
    And The JSON coverage report should have been generated for "RSpecTracer"
    And The coverage percent stat is "27 / 41 LOC (65.85%) covered"
    And The JSON coverage report should have correct coverage for "RSpecTracer"
    Given I use test suite id 2
    When I run `bundle exec rspec spec/student_spec.rb`
    Then The RSpecTracer should print the information
      """
        Started RSpec tracer
        RSpec tracer is running 2 examples (actual: 8, skipped: 6)
        does not set email (Pending previously) (PENDING: Temporarily skipped with xcontext)
        enroll student (Failed previously) (FAILED - 1)
        2 examples, 1 failure, 1 pending
        RSpec tracer is generating reports
      """
    And The RSpecTracer report should have been generated
    And The last run report should have correct details
      """
      {
        "run_id": "2c48486d4513ef0eeee4e7ab8c284419",
        "actual_count": 8,
        "example_count": 2,
        "skipped_examples": 6,
        "failed_examples": 1,
        "pending_examples": 1
      }
      """
    And The all examples report should have correct details
    And The all files report should have correct details
      | file_name             | file_digest                       |
      | /spec/spec_helper.rb  | 23dbc48fca7c1ef0cc63cd04f76977f8  |
      | /spec/student_spec.rb | 822cf79c51add2d042df1e4a46ec98be  |
      | /app/student.rb       | 831c0dc99ff5690f98eb92af131931dd  |
    And The dependency report should have correct details
    And The reverse dependency report should have correct details
    And The JSON coverage report should have been generated for "RSpecTracer"
    And The coverage percent stat is "17 / 41 LOC (41.46%) covered"
    And The JSON coverage report should have correct coverage for "RSpecTracer"
    Given I reset test suite id
    When I run `bundle exec rspec spec`
    Then The RSpecTracer should print the information
      """
        Started RSpec tracer
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
      """
    And The RSpecTracer report should have been generated
    And The last run report should have correct details
      """
      {
        "run_id": "63df6c782675a201fbef23140bd868e2",
        "actual_count": 10,
        "example_count": 10,
        "skipped_examples": 0,
        "failed_examples": 1,
        "pending_examples": 1
      }
      """
    And The all examples report should have correct details
    And The all files report should have correct details
      | file_name             | file_digest                       |
      | /spec/spec_helper.rb  | 23dbc48fca7c1ef0cc63cd04f76977f8  |
      | /spec/course_spec.rb  | 7564705d731dd1521626cc08baaca4ee  |
      | /spec/student_spec.rb | 822cf79c51add2d042df1e4a46ec98be  |
      | /app/course.rb        | d70df28269ceb244b4a3620644990ffd  |
      | /app/student.rb       | 831c0dc99ff5690f98eb92af131931dd  |
    And The failed example report should have correct details
    And The pending example report should have correct details
    And The dependency report should have correct details
    And The reverse dependency report should have correct details
    And The JSON coverage report should have been generated for "RSpecTracer"
    And The coverage percent stat is "32 / 41 LOC (78.05%) covered"
    And The JSON coverage report should have correct coverage for "RSpecTracer"
