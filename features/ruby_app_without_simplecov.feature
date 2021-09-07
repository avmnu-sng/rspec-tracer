@ruby-app @no-simplecov @disable-bundler
Feature: Ruby App without SimpleCov

  Adding rspec-tracer without simplecov should generate tracer reports and the
  coverage report as well. It should skip some examples when cache found and no
  dependency change is detected.

  Scenario: Ruby App without SimpleCov
    Given I am working on the project "ruby_app"
    And I use "without_simplecov.rb" as spec helper
    When I run specs using "rspec spec"
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
    When I run `bundle exec rspec spec`
    Then The RSpecTracer should print the information
      """
        Started RSpec tracer
        RSpec tracer is running 2 examples (actual: 10, skipped: 8)
        does not enroll (Failed previously) (FAILED - 1)
        does not set email (Pending previously) (PENDING: Temporarily skipped with xcontext)
        2 examples, 1 failure, 1 pending
        RSpec tracer is generating reports
      """
    And The RSpecTracer report should have been generated
    And The last run report should have correct details
      """
      {
        "run_id": "63df6c782675a201fbef23140bd868e2",
        "actual_count": 10,
        "example_count": 2,
        "skipped_examples": 8,
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
    Given I replace spec helper with "without_simplecov_updated.rb"
    When I run `bundle exec rspec spec`
    Then The RSpecTracer should print the information
      """
        Started RSpec tracer
        RSpec tracer is running 10 examples (actual: 10, skipped: 0)
        does not enroll (Failed previously) (FAILED - 1)
        does not set email (Pending previously) (PENDING: Temporarily skipped with xcontext)
        enrolls student (Files changed)
        does not set name (Files changed)
        sets name (Files changed)
        sets email (Files changed)
        does not set mobile (Files changed)
        sets mobile (Files changed)
        does not enroll (Files changed)
        enroll student (Files changed)
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
      | /spec/spec_helper.rb  | d97e79bc9bdf5eaaa455ad7bdc2f555a  |
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
    When I run `bundle exec rspec spec`
    Then The RSpecTracer should print the information
      """
        Started RSpec tracer
        RSpec tracer is running 2 examples (actual: 10, skipped: 8)
        does not enroll (Failed previously) (FAILED - 1)
        does not set email (Pending previously) (PENDING: Temporarily skipped with xcontext)
        2 examples, 1 failure, 1 pending
        RSpec tracer is generating reports
      """
    And The RSpecTracer report should have been generated
    And The last run report should have correct details
      """
      {
        "run_id": "63df6c782675a201fbef23140bd868e2",
        "actual_count": 10,
        "example_count": 2,
        "skipped_examples": 8,
        "failed_examples": 1,
        "pending_examples": 1
      }
      """
    And The all examples report should have correct details
    And The all files report should have correct details
      | file_name             | file_digest                       |
      | /spec/spec_helper.rb  | d97e79bc9bdf5eaaa455ad7bdc2f555a  |
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
        "run_id": "63df6c782675a201fbef23140bd868e2",
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
      | /spec/spec_helper.rb  | d97e79bc9bdf5eaaa455ad7bdc2f555a  |
      | /spec/course_spec.rb  | 7564705d731dd1521626cc08baaca4ee  |
      | /spec/student_spec.rb | 822cf79c51add2d042df1e4a46ec98be  |
      | /app/course.rb        | d70df28269ceb244b4a3620644990ffd  |
      | /app/student.rb       | 831c0dc99ff5690f98eb92af131931dd  |
    And The failed example report should have correct details
    And The pending example report should have correct details
    And The dependency report should have correct details
    And The reverse dependency report should have correct details
    And The JSON coverage report should have been generated for "RSpecTracer"
    And The coverage percent stat is "27 / 41 LOC (65.85%) covered"
    When I run `bundle exec rspec spec/student_spec.rb`
    Then The RSpecTracer should print the information
      """
        Started RSpec tracer
        RSpec tracer is running 1 examples (actual: 8, skipped: 7)
        does not set email (Pending previously) (PENDING: Temporarily skipped with xcontext)
        1 example, 0 failures, 1 pending
        RSpec tracer is generating reports
      """
    And The RSpecTracer report should have been generated
    And The last run report should have correct details
      """
      {
        "run_id": "63df6c782675a201fbef23140bd868e2",
        "actual_count": 8,
        "example_count": 1,
        "skipped_examples": 7,
        "failed_examples": 0,
        "pending_examples": 1
      }
      """
    And The all examples report should have correct details
    And The all files report should have correct details
      | file_name             | file_digest                       |
      | /spec/spec_helper.rb  | d97e79bc9bdf5eaaa455ad7bdc2f555a  |
      | /spec/course_spec.rb  | 7564705d731dd1521626cc08baaca4ee  |
      | /spec/student_spec.rb | 822cf79c51add2d042df1e4a46ec98be  |
      | /app/course.rb        | d70df28269ceb244b4a3620644990ffd  |
      | /app/student.rb       | 831c0dc99ff5690f98eb92af131931dd  |
    And The failed example report should have correct details
    And The pending example report should have correct details
    And The dependency report should have correct details
    And The reverse dependency report should have correct details
    And The JSON coverage report should have been generated for "RSpecTracer"
    And The coverage percent stat is "25 / 41 LOC (60.98%) covered"
    When I run `bundle exec rspec spec`
    Then The RSpecTracer should print the information
      """
        Started RSpec tracer
        RSpec tracer is running 2 examples (actual: 10, skipped: 8)
        does not enroll (Failed previously) (FAILED - 1)
        does not set email (Pending previously) (PENDING: Temporarily skipped with xcontext)
        2 examples, 1 failure, 1 pending
        RSpec tracer is generating reports
      """
    And The RSpecTracer report should have been generated
    And The last run report should have correct details
      """
      {
        "run_id": "63df6c782675a201fbef23140bd868e2",
        "actual_count": 10,
        "example_count": 2,
        "skipped_examples": 8,
        "failed_examples": 1,
        "pending_examples": 1
      }
      """
    And The all examples report should have correct details
    And The all files report should have correct details
      | file_name             | file_digest                       |
      | /spec/spec_helper.rb  | d97e79bc9bdf5eaaa455ad7bdc2f555a  |
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
