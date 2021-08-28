![](./readme_files/rspec_tracer.png)

## Intention

It's just not about reducing the time taken to run tests but also getting answers
to questions that come before thinking about writing a single-line code. At times,
we don't know which other components require testing because of the changes introduced.
One possible way to have insights on this is to know which spec files would run
some or all the tests when changing a specific source or spec file.

Since we know that a particular file is testing a specific component or feature,
we get some idea of what else could change and whether it's desirable or not. We
can also analyze the dependency amongst these components and retrospect the design
choices made with this data. Indeed, this also comes in handy when we are refactoring
the code-base. We can pick pieces with the least number of dependencies and avoid any
surprises.

```json
{
  "app/course.rb": [
    "spec/course_spec.rb", "spec/student_spec.rb"
  ],
  "app/student.rb": [
    "spec/course_spec.rb", "spec/student_spec.rb"
  ],
  "spec/course_spec.rb": [
    "spec/course_spec.rb"
  ],
  "spec/spec_helper.rb": [
    "spec/course_spec.rb", "spec/student_spec.rb"
  ],
  "spec/student_spec.rb": [
    "spec/student_spec.rb"
  ]
}
```

Okay, now about the test execution time. There is an option to run tests parallel
and save time, but it runs all the tests. If we know for a fact that in the
current state, a given set of tests needs run, why run the entire suite? Earlier,
we talked about maintaining a map of files to spec files, but it is not helpful here.
What we need is a map of the test to source and spec files. With this, we can check
if any of the files changed or not. If not, no need to run this particular test.

```json
{
  "RSpec::ExampleGroups::Course::Enrolled::WithStudent#enrolls student": [
    "app/course.rb", "app/student.rb", "spec/course_spec.rb", "spec/spec_helper.rb"
  ],
  "RSpec::ExampleGroups::Course::Enrolled::WithoutStudent#does not enroll": [
    "app/course.rb", "spec/course_spec.rb", "spec/spec_helper.rb"
  ],
  "RSpec::ExampleGroups::Student::Email::WithEmail#sets email": [
    "app/student.rb", "spec/spec_helper.rb", "spec/student_spec.rb"
  ],
  "RSpec::ExampleGroups::Student::Email::WithoutEmail#does not set email": [
    "spec/spec_helper.rb", "spec/student_spec.rb"
  ],
  "RSpec::ExampleGroups::Student::Enroll::WithCourse#enroll student": [
    "app/course.rb", "app/student.rb", "spec/spec_helper.rb", "spec/student_spec.rb"
  ],
  "RSpec::ExampleGroups::Student::Enroll::WithoutCourse#does not enroll": [
    "app/student.rb", "spec/spec_helper.rb", "spec/student_spec.rb"
  ],
  "RSpec::ExampleGroups::Student::Mobile::WithMobile#sets mobile": [
    "app/student.rb", "spec/spec_helper.rb", "spec/student_spec.rb"
  ],
  "RSpec::ExampleGroups::Student::Mobile::WithoutMobile#does not set mobile": [
    "app/student.rb", "spec/spec_helper.rb", "spec/student_spec.rb"
  ],
  "RSpec::ExampleGroups::Student::Name::WithName#sets name": [
    "app/student.rb", "spec/spec_helper.rb", "spec/student_spec.rb"
  ],
  "RSpec::ExampleGroups::Student::Name::WithoutName#does not set name": [
    "app/student.rb", "spec/spec_helper.rb", "spec/student_spec.rb"
  ]
}
```

Let's see how we can create both these two maps.

## Creating Dependency Map

We will maintain reference coverage data, and then at the end of each test run,
we find all such files which have coverage diff. These are the files on which
this particular test depends.

```ruby
# List of tests we are running
tests = []
# Dependencies map
deps = {}

# Before starting execution of test suite
# Store the reference coverage
ref_cov = Coverage.peek_result

tests.each do |test|
  # Run test
  test.run

  # After test is run
  test.after_run do
    # Store the current coverage
    curr_cov = Coverage.peek_result

    # Find all the files with some coverage diff
    deps[test] = changed_files(ref_cov, curr_cov)

    # Update the reference coverage for next test
    ref_cov = curr_cov
  end
end
```

That's all we need to have the tests to files dependencies. Suppose the map looks
like:

```ruby
{
  'test_1' => %w[spec_file_1.rb source_file_1.rb source_file_2.rb],
  'test_2' => %w[spec_file_1.rb source_file_2.rb],
  'test_3' => %w[spec_file_3.rb source_file_4.rb],
  'test_4' => %w[spec_file_2.rb source_file_1.rb source_file_3.rb]
}
```

Looking at the map, we can say:

- We only need to run `test_2` if one or more dependent files (`spec_file_1.rb`,
`source_file_2.rb`) change.
- Similarly, run `test_4` if any of the `spec_file_2.rb`, `source_file_1.rb`,
and `source_file_3.rb` change.

Using this map, we can create the source and spec files to dependent spec files
map:

```ruby
# Test to spec file map, i.e., which spec file defines this particular test
tests = {}
# Test to files dependencies map
deps = {}
# File to spec files dependencies map
file_deps = Hash.new { |hash, key| hash[key] = Set.new }

deps.each_pair do |test, files|
  files.each do |file|
    file_deps[file] << tests[test]
  end
end
```

Assuming:

- `spec_file_1.rb` defines `test_1` and `test_2`.
- `spec_file_2.rb` defines `test_4`.
- `spec_file_3.rb` defines `test_3`.

We get the following map:

```ruby
{
  'source_file_1.rb'  => %w[spec_file_1.rb spec_file_2.rb],
  'source_file_2.rb'  => %w[spec_file_1.rb],
  'source_file_3.rb'  => %w[spec_file_2.rb],
  'source_file_4.rb'  => %w[spec_file_3.rb],
  'spec_file_1.rb'    => %w[spec_file_1.rb],
  'spec_file_2.rb'    => %w[spec_file_2.rb],
  'spec_file_3.rb'    => %w[spec_file_3.rb]
}
```

## Using Dependency Map

As we have the test dependency map, we can use it to skip tests with no dependency
changes.

```ruby
tests.each do |test|
  test.before_run do
    # Skip if no dependency changed
    test.skip if deps[test].none? { |file| changed?(file) }
  end

  # Run test, otherwise
  test.run
end
```

## Maintaining Coverage

Since we are skipping tests, the coverage data will not include contributions
from these tests. Note that we can store the coverage data for each test while
computing the dependency and then add this to the coverage report.

```ruby
tests.each do |test|
  # Run test
  test.run

  # After test is run
  test.after_run do
    # Store the current coverage
    curr_cov = Coverage.peek_result

    # Find all the files with some coverage diff
    deps[test] = changed_files(ref_cov, curr_cov)
    # Store the coverage diff, i.e., contribution of this test only
    cov[test] = cov_diff(ref_cov, curr_cov)

    # Update the reference coverage for next test
    ref_cov = curr_cov
  end
end

# For all the tests we skipped
skipped_tests.each { |test| final_cov.sum(cov[test]) }
```
