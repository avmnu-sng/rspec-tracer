@parallel-tests @ruby-app @no-simplecov @disable-bundler
Feature: Parallel Tests Ruby App with Many Spec Files without SimpleCov

  Adding rspec-tracer without simplecov should generate tracer reports and the
  coverage report as well. It should skip some examples when cache found and no
  dependency change is detected.

  Scenario: Parallel Tests Ruby App with Many Spec Files without SimpleCov
    Given I am working on the project "parallel_tests_ruby_app_many_spec_files"
    When I cd to "project"
    And I run specs using "parallel_rspec spec"
    Then The RSpecTracer should print the information
      """
        Started RSpec tracer
        does not enroll (No cache) (FAILED - 1)
        enrolls student (No cache)
        does not set name (No cache)
        sets name (No cache)
        does not set email (No cache) (PENDING: Temporarily skipped with xcontext)
        sets email (No cache)
        does not set mobile (No cache)
        sets mobile (No cache)
        does not enroll (No cache)
        enroll student (No cache) (FAILED - 1)
        validates twice of the num (No cache)
        241 examples, 2 failures, 1 pending
        RSpec tracer is generating reports
        RSpec tracer merged parallel tests reports
      """
    And The parallel processes information should have printed for 23 spec files
    And The RSpecTracer report should have been generated
    And The last run report should have correct details
      """
      {
        "run_id": "60d5ac9453a7d86d238b92992ca20540",
        "actual_count": 241,
        "example_count": 241,
        "skipped_examples": 0,
        "failed_examples": 2,
        "pending_examples": 1
      }
      """
    And The all examples report should have correct details
    And The all files report should have correct details
      | file_name               | file_digest                       |
      | /spec/spec_helper.rb    | 23dbc48fca7c1ef0cc63cd04f76977f8  |
      | /spec/course_spec.rb    | 7564705d731dd1521626cc08baaca4ee  |
      | /spec/student_spec.rb   | 822cf79c51add2d042df1e4a46ec98be  |
      | /spec/dummy_1_spec.rb   | 2a0c5ff3e3d6e8a7f291484aae5999c9  |
      | /spec/dummy_2_spec.rb   | 390ddd9fa8b441b4582619675933bacd  |
      | /spec/dummy_3_spec.rb   | 42496ed9933b78085a220903627e8ded  |
      | /spec/dummy_4_spec.rb   | f2e40a141c5d3bed9cac5f3b3e0e798b  |
      | /spec/dummy_5_spec.rb   | 8794e591c030ba6c99bf085387e076d1  |
      | /spec/dummy_6_spec.rb   | 58270a02d67136a4c8390fac50e68d7c  |
      | /spec/dummy_7_spec.rb   | 70f5680f7e05a1966abce265b6ffaa83  |
      | /spec/dummy_8_spec.rb   | 9650713962d370d1f7d662addf758068  |
      | /spec/dummy_9_spec.rb   | 4c96d4845d8600cd50b6c7107ccdd3b1  |
      | /spec/dummy_10_spec.rb  | ee74b903746bedba670bb62ba3e8627c  |
      | /spec/dummy_11_spec.rb  | 4a925e25b74115eef2e14c8649c7d3a9  |
      | /spec/dummy_12_spec.rb  | abda7499d5708db824be4d3aaa0b6ee4  |
      | /spec/dummy_13_spec.rb  | c53eff4cb8958b863742a9c121b01cef  |
      | /spec/dummy_14_spec.rb  | f878e7a0b0558ea59200fd47c2be66c6  |
      | /spec/dummy_15_spec.rb  | 63122ff23cc46a455e25435fd843648c  |
      | /spec/dummy_16_spec.rb  | 8e7c2f074ca9a5d10a1f3fd7690013bf  |
      | /spec/dummy_17_spec.rb  | d3adf16f38743c42fd62d71d2014e244  |
      | /spec/dummy_18_spec.rb  | ca1c62bd4b1a0ceedaab9ba8cc504040  |
      | /spec/dummy_19_spec.rb  | c1fee5ba31326ff0696a12fd87179735  |
      | /spec/dummy_20_spec.rb  | dfd5d6f6c9208292fc973bfd1ef5ee65  |
      | /spec/dummy_21_spec.rb  | 1ddcfaf9fea5439920dfdb75a44f5f83  |
      | /app/course.rb          | d70df28269ceb244b4a3620644990ffd  |
      | /app/student.rb         | 831c0dc99ff5690f98eb92af131931dd  |
    And The failed example report should have correct details
    And The pending example report should have correct details
    And The dependency report should have correct details
    And The reverse dependency report should have correct details
    And The JSON coverage report should have been generated for "RSpecTracer"
    And The coverage percent stat is "30 / 41 LOC (73.17%) covered"
    And The JSON coverage report should have correct coverage for "RSpecTracer"
    When I run `bundle exec parallel_rspec spec`
    Then The RSpecTracer should print the information
      """
        Started RSpec tracer
        does not enroll (Failed previously) (FAILED - 1)
        does not set email (Pending previously) (PENDING: Temporarily skipped with xcontext)
        enroll student (Failed previously) (FAILED - 1)
        1 example, 1 failure
        2 examples, 1 failure, 1 pending
        3 examples, 2 failures, 1 pending
        RSpec tracer is generating reports
        RSpec tracer merged parallel tests reports
      """
    And The parallel processes information should have printed for 23 spec files
    And The RSpecTracer report should have been generated
    And The last run report should have correct details
      """
      {
        "run_id": "60d5ac9453a7d86d238b92992ca20540",
        "actual_count": 241,
        "example_count": 3,
        "skipped_examples": 238,
        "failed_examples": 2,
        "pending_examples": 1
      }
      """
    And The all examples report should have correct details
    And The all files report should have correct details
      | file_name               | file_digest                       |
      | /spec/spec_helper.rb    | 23dbc48fca7c1ef0cc63cd04f76977f8  |
      | /spec/course_spec.rb    | 7564705d731dd1521626cc08baaca4ee  |
      | /spec/student_spec.rb   | 822cf79c51add2d042df1e4a46ec98be  |
      | /spec/dummy_1_spec.rb   | 2a0c5ff3e3d6e8a7f291484aae5999c9  |
      | /spec/dummy_2_spec.rb   | 390ddd9fa8b441b4582619675933bacd  |
      | /spec/dummy_3_spec.rb   | 42496ed9933b78085a220903627e8ded  |
      | /spec/dummy_4_spec.rb   | f2e40a141c5d3bed9cac5f3b3e0e798b  |
      | /spec/dummy_5_spec.rb   | 8794e591c030ba6c99bf085387e076d1  |
      | /spec/dummy_6_spec.rb   | 58270a02d67136a4c8390fac50e68d7c  |
      | /spec/dummy_7_spec.rb   | 70f5680f7e05a1966abce265b6ffaa83  |
      | /spec/dummy_8_spec.rb   | 9650713962d370d1f7d662addf758068  |
      | /spec/dummy_9_spec.rb   | 4c96d4845d8600cd50b6c7107ccdd3b1  |
      | /spec/dummy_10_spec.rb  | ee74b903746bedba670bb62ba3e8627c  |
      | /spec/dummy_11_spec.rb  | 4a925e25b74115eef2e14c8649c7d3a9  |
      | /spec/dummy_12_spec.rb  | abda7499d5708db824be4d3aaa0b6ee4  |
      | /spec/dummy_13_spec.rb  | c53eff4cb8958b863742a9c121b01cef  |
      | /spec/dummy_14_spec.rb  | f878e7a0b0558ea59200fd47c2be66c6  |
      | /spec/dummy_15_spec.rb  | 63122ff23cc46a455e25435fd843648c  |
      | /spec/dummy_16_spec.rb  | 8e7c2f074ca9a5d10a1f3fd7690013bf  |
      | /spec/dummy_17_spec.rb  | d3adf16f38743c42fd62d71d2014e244  |
      | /spec/dummy_18_spec.rb  | ca1c62bd4b1a0ceedaab9ba8cc504040  |
      | /spec/dummy_19_spec.rb  | c1fee5ba31326ff0696a12fd87179735  |
      | /spec/dummy_20_spec.rb  | dfd5d6f6c9208292fc973bfd1ef5ee65  |
      | /spec/dummy_21_spec.rb  | 1ddcfaf9fea5439920dfdb75a44f5f83  |
      | /app/course.rb          | d70df28269ceb244b4a3620644990ffd  |
      | /app/student.rb         | 831c0dc99ff5690f98eb92af131931dd  |
    And The failed example report should have correct details
    And The pending example report should have correct details
    And The dependency report should have correct details
    And The reverse dependency report should have correct details
    And The JSON coverage report should have been generated for "RSpecTracer"
    And The coverage percent stat is "30 / 41 LOC (73.17%) covered"
    And The JSON coverage report should have correct coverage for "RSpecTracer"
