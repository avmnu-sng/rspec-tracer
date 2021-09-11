![](./readme_files/rspec_tracer.png)

This document sheds some light on why RSpec Tracer might be helpful and talks
about implementation details of **managing dependency**, **managing flaky tests**,
**skipping tests**, and **caching on CI**.

## Table of Contents

* [Intention](#intention)
* [Managing Dependency](#managing-dependency)
  * [Creating Dependency Map](#creating-dependency-map)
  * [Using Dependency Map](#using-dependency-map)
  * [Maintaining Coverage](#maintaining-coverage)
* [Flaky Tests](#flaky-tests)
* [Caching on CI](#caching-on-ci)
  * [Handling History Rewrites](#handling-history-rewrites)
  * [Handling Merge Commits](#handling-merge-commits)
  * [Handling Shallow Clone](#handling-shallow-clone)
    * [Recommendation](#recommendation)
  * [Finding the Nearest Cache](#finding-the-nearest-cache)

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

## Managing Dependency

There is an option to run tests parallel and save time, but it runs all the tests.
If we know for a fact that in the current state, a given set of tests needs run,
why run the entire suite? Earlier, we talked about maintaining a map of files to
spec files, but it is not helpful here. What we need is a map of the test to source
and spec files. With this, we can check if any of the files changed or not. If not,
no need to run this particular test.

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

### Creating Dependency Map

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

### Using Dependency Map

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

### Maintaining Coverage

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

## Flaky Tests

Sometimes we have flaky tests, and it is tough to find out such tests. No worries,
RSpec Tracer will do it for you. It takes care of the scenarios when some previously
failing tests pass in the current run without any dependency change and flag them
as flaky. It would keep running these tests irrespective of the execution result
unless you changed the dependent files.

## Caching on CI

We can use the commit objects to refer to a previous run cache files set. We
traverse the **Git ancestry** for each run to find the nearest commit SHA with the
proper cache files. Assuming `BRANCH_REF` denotes the commit SHA to upload the
cache files, i.e., the most accurate commit SHA on the PR branch. It will always
be the `HEAD` ref on the **main** branch.

The following command fetches the list of 25 commits starting from the branch ref:

```sh
$ git rev-list --max-count=25 --topo-order $BRANCH_REF
```

### Handling History Rewrites

If you use `git commit --amend`, `git pull -r origin main`, and `git merge origin/main`,
etc., then the commit SHA will change, and the last run remote cache reference is lost.
Since Git uses the [directed acyclic graph](https://en.wikipedia.org/wiki/Directed_acyclic_graph)
data structure, the previous commits refs are not entirely lost. We can use the
current commit SHA to find these:

```sh
$ git fsck --no-progress --unreachable --connectivity-only $BRANCH_REF \
  | awk '/commit/ { print $3 }' \
  | head -n 25
```

### Handling Merge Commits

For the case when we merge the main branch into the feature branch, nothing special
is required. But mostly, all the CI use the `refs/pull/<number>/merge` reference
created by GitHub to track what would happen if you merged the pull request. It
references the merge commit between `refs/pull/<number>/head` and the target branch.
Technically, it is a future commit, so it will not be part of the Git ancestry in
the subsequent runs. Therefore, we cannot annotate cache files using this commit SHA.

So, how to deal with such a case? We know that each merge commit has two immediate
parents. You can use the following command to list both these:

```sh
$ git rev-parse HEAD^@
```

Note that in this case, the second parent, i.e., `git rev-parse HEAD^2` is the
current branch HEAD, i.e., `refs/pull/<number>/head`. We need is to ignore
all such commit SHA for referencing the cache files:

```sh
$ git rev-list $BRANCH_REF..origin/HEAD
```

### Handling Shallow Clone

When we configure CI to shallow clone the repository (using `--depth` option),
the root commit is marked as grafted. It works by letting users record fake ancestry
information for commits. Consider the following Git graph:

```sh
$ git log --all --max-count=10 --decorate --oneline --graph

*   b110b730b3 (HEAD) Merge a893fa0677 into 5b6cc57e74
|\
| * a893fa0677 grault
| * fc3d894156 corge
| * 6d45b211f8 quuz
| * 8b4713af1f quux
| * b6033a4f80 qux
| * 0f7afab0b5 baz
| * b6bec52e93 bar
| * 64a913bc9a foo
| * f1b476a9ed foobar
```

Notice that the commit `5b6cc57e74` is not part of the above graph.

```sh
$ git log --all --max-count=11 --oneline

b110b730b3 (HEAD) Merge a893fa0677 into 5b6cc57e74
5b6cc57e74 (grafted, origin/main, origin/HEAD, main) garply
a893fa0677 grault
fc3d894156 corge
6d45b211f8 quuz
8b4713af1f quux
b6033a4f80 qux
0f7afab0b5 baz
b6bec52e93 bar
64a913bc9a foo
f1b476a9ed foobar
```

On the CI, it changes the following two things for us:

- The unreachable commits list will always have **two entries**, `HEAD` and the
`grafted` commits:
    ```sh
    $ git fsck --no-progress --unreachable --connectivity-only $BRANCH_REF \
      | awk '/commit/ { print $3 }'

    5b6cc57e74
    b110b730b3
    ```

- The ignorable commit is always the `grafted` one:
    ```sh
    $ git rev-list $BRANCH_REF..origin/HEAD

    5b6cc57e74
    ```

#### Recommendation

To fully utilize the caching feature, you should make a complete clone, or at
least `--depth=50` because the RSpec Tracer tries to find the nearest cache from
the **25 unreachable** and **25 ancestry** commits.

### Finding the Nearest Cache

As we have the list of commit SHA, we need to validate and find the best one for
us, i.e., sometimes, a few commits from the list will not be available, and some
might not have finished yet. For example, consider pulling changes from the main
branch the moment it started running build and creating a PR. In this case, the
PR should not use the main branch SHA because it has incomplete cache files pushed
to S3.

RSpec Tracer generates **nine** files for each run, so if you run tests in different
suites, say, **5**, then the full cache has **45** objects. Therefore, we can first
find such a commit and then download the files.

