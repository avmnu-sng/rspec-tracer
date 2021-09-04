![](./readme_files/rspec_tracer.png)

RSpec Tracer is a **specs dependency analysis tool** and a **test skipper for RSpec**.
It maintains a list of files for each test, enabling itself to skip tests in the
subsequent runs if none of the dependent files are changed.

It uses [Ruby's built-in coverage library](https://ruby-doc.org/stdlib/libdoc/coverage/rdoc/Coverage.html)
to keep track of the coverage for each test. For each test executed, the coverage
diff provides the desired file list. RSpec Tracer takes care of reporting the
**correct code coverage when skipping tests** by using the cached reports. Also,
note that it will **never skip**:

- **Flaky examples**
- **Failed examples**
- **Pending examples**

Knowing the examples and files dependency gives us a better insight into the codebase,
and we have **a clear idea of what to test for when making any changes**. With this data,
we can also analyze the coupling between different components and much more.

## Note

You should take some time and go through the [document](./RSPEC_TRACER.md) describing
the **intention** and implementation details of **managing dependency**, **managing flaky tests**,
**skipping tests**, and **caching on CI**.

## Table of Contents

* [Demo](#demo)
* [Installation](#installation)
  * [Compatibility](#compatibility)
  * [Additional Tools](#additional-tools)
* [Getting Started](#getting-started)
* [Environment Variables](#environment-variables)
  * [CI](#ci)
  * [LOCAL_AWS](#local_aws)
  * [RSPEC_TRACER_NO_SKIP](#rspec_tracer_no_skip)
  * [RSPEC_TRACER_S3_URI](#rspec_tracer_s3_uri)
  * [RSPEC_TRACER_UPLOAD_LOCAL_CACHE](#rspec_tracer_upload_local_cache)
  * [TEST_SUITES](#test_suites)
  * [TEST_SUITE_ID](#test_suite_id)
* [Sample Reports](#sample-reports)
    * [Examples](#examples)
    * [Flaky Examples](#flaky-examples)
    * [Examples Dependency](#examples-dependency)
    * [Files Dependency](#files-dependency)
* [Configuring RSpec Tracer](#configuring-rspec-tracer)
* [Filters](#filters)
  * [Defining Custom Filteres](#defining-custom-filteres)
    * [String Filter](#string-filter)
    * [Regex Filter](#regex-filter)
    * [Block Filter](#block-filter)
    * [Array Filter](#array-filter)
* [Contributing](#contributing)
* [License](#license)
* [Code of Conduct](#code-of-conduct)

## Demo

**First Run**
![](./readme_files/first_run.gif)

**Next Run**
![](./readme_files/next_run.gif)


## Installation

Add this line to your `Gemfile` and `bundle install`:
```ruby
gem 'rspec-tracer', group: :test, require: false
```

And, add the followings to your `.gitignore`:
```
/rspec_tracer_cache/
/rspec_tracer_coverage/
/rspec_tracer_report/
```

### Compatibility

RSpec Tracer requires **Ruby 2.5+** and **rspec-core >= 3.6.0**. To use with **Rails 5+**,
make sure to use **rspec-rails >= 4.0.0**. If you are using SimpleCov, it is
recommended to use **simplecov >= 0.12.0**.

### Additional Tools

To use RSpec Tracer on CI, you need to have an **S3 bucket** and
**[AWS CLI](https://aws.amazon.com/cli/)** installed.

## Getting Started

1. **Load and Start RSpec Tracer**

    - **With SimpleCov**

        If you are using `SimpleCov`, load RSpec Tracer right after the SimpleCov load
        and launch:

        ```ruby
        require 'simplecov'
        SimpleCov.start

        # Load RSpec Tracer
        require 'rspec_tracer'
        RSpecTracer.start
        ```

        Currently using RSpec Tracer with SimpleCov has the following two limitations:
        - SimpleCov **won't be able to provide branch coverage report** even when enabled.
        - RSpec Tracer **nullifies the `SimpleCov.at_exit`** callback.

    - **Without SimpleCov**

        Load and launch RSpec Tracer at the very top of `spec_helper.rb` (or `rails_helper.rb`,
        `test/test_helper.rb`). Note that `RSpecTracer.start` must be issued **before loading
        any of the application code.**

        ```ruby
        # Load RSpec Tracer
        require 'rspec_tracer'
        RSpecTracer.start
        ```

2. To enable RSpec Tracer to share cache between different builds on CI, update the
Rakefile in your project to have the following:

    ```ruby
    spec = Gem::Specification.find_by_name('rspec-tracer')

    load "#{spec.gem_dir}/lib/rspec_tracer/remote_cache/Rakefile"
    ```
3. Before running tests, download the remote cache using the following rake task:

    ```sh
    bundle exec rake rspec_tracer:remote_cache:download
    ```
4. Run the tests with RSpec using `bundle exec rspec`.
5. After running tests, upload the local cache using the following rake task:

    ```sh
    bundle exec rake rspec_tracer:remote_cache:upload
    ```
6. After running your tests, open `rspec_tracer_report/index.html` in the
browser of your choice.

## Environment Variables

To get better control on execution, you can use the following two environment variables:

### CI

Mostly all the CI have `CI=true`. If not, you should explicitly set it to `true`.

### LOCAL_AWS

In case you want to test out the caching feature in the local development environment.
You can install [localstack](https://github.com/localstack/localstack) and
[awscli-local](https://github.com/localstack/awscli-local) and then invoke the
rake tasks with `LOCAL_AWS=true`.

### RSPEC_TRACER_NO_SKIP

The default value is `false.` If set to `true`, the RSpec Tracer will not skip
any tests. Note that it will continue to maintain cache files and generate reports.

```ruby
RSPEC_TRACER_NO_SKIP=true bundle exec rspec
```

### RSPEC_TRACER_S3_URI

You should provide the S3 bucket path to store the cache files.

```ruby
export RSPEC_TRACER_S3_URI=s3://ci-artifacts-bucket/rspec-tracer-cache
```

### RSPEC_TRACER_UPLOAD_LOCAL_CACHE

By default, RSpec Tracer does not upload local cache files. You can set this
environment variable to `true` to upload the local cache to S3.

### TEST_SUITES

Set this environment variable when using test suite id. It determines the total
number of different test suites you are running.

```ruby
export TEST_SUITES=8
```

### TEST_SUITE_ID

If you have a large set of tests to run, it is recommended to run them in
separate groups. This way, RSpec Tracer is not overwhelmed with loading massive
cached data in the memory. Also, it generate and use cache for specific test suites
and not merge them.

```ruby
TEST_SUITE_ID=1 bundle exec rspec spec/models
TEST_SUITE_ID=2 bundle exec rspec spec/helpers
```

If you run parallel builds on the CI, you should specify the test suite ID and
the total number of test suites when downloading the cache files.

```sh
$ TEST_SUITES=5 TEST_SUITE_ID=1 bundle exec rake rspec_tracer:remote_cache:download
```

In this case, the appropriate cache should have all the cache files available on
the S3 for each test suite, not just for the current one. Also, while uploading,
make sure to provide the test suite id.

```sh
$ TEST_SUITE_ID=1 bundle exec rake rspec_tracer:remote_cache:upload
```

## Sample Reports

You get the following three reports:

### Examples

These reports provide basic test information:

**First Run**

![](./readme_files/examples_report_first_run.png)

**Next Run**

![](./readme_files/examples_report_next_run.png)

### Flaky Examples

These reports provide flaky tests information. Assuming **the following two tests
failed in the first run.**

**Next Run**

![](./readme_files/flaky_examples_report_first_run.png)

**Another Run**

![](./readme_files/flaky_examples_report_next_run.png)

### Examples Dependency

These reports show a list of dependent files for each test.

![](./readme_files/examples_dependency_report.png)

### Files Dependency

These reports provide information on the total number of tests that will run after changing this particular file.

![](./readme_files/files_dependency_report.png)

## Configuring RSpec Tracer

Configuration settings can be applied in three formats, which are completely equivalent:

- The most common way is to configure it directly in your start block:

    ```ruby
    RSpecTracer.start do
      config_option 'foo'
    end
    ```
- You can also set all configuration options directly:

    ```ruby
    RSpecTracer.config_option 'foo'
    ```

- If you do not want to start tracer immediately after launch or want to add
additional configuration later on in a concise way, use:

    ```ruby
    RSpecTracer.configure do
      config_option 'foo'
    end
    ```

## Filters

RSpec Tracer supports two types of filters:

- To exclude selected files from the dependency list of tests:

    ```ruby
    RSpecTracer.start do
      add_filter %r{^/helpers/}
    end
    ```
- To exclude selected files from the coverage data. You should only use this
when not using SimpleCov.

    ```ruby
    RSpecTracer.start do
      add_coverage_filter %r{^/tasks/}
    end
    ```

By default, a filter is applied that removes all files OUTSIDE of your project's
root directory - otherwise you'd end up with the source files in the gems you are
using as tests dependency.

### Defining Custom Filteres

You can currently define a filter using either a String or Regexp (that will then
be Regexp-matched against each source file's path), a block or by passing in your
own Filter class.

#### String Filter

```ruby
RSpecTracer.start do
  add_filter '/helpers/'
end
```

This simple string filter will remove all files that match "/helpers/" in their path.

#### Regex Filter

```ruby
RSpecTracer.start do
  add_filter %r{^/helpers/}
end
```

This simple regex filter will remove all files that start with /helper/ in their path.

#### Block Filter

```ruby
RSpecTracer.start do
  add_filter do |source_file|
    source_file[:file_path].include?('/helpers/')
  end
end
```

Block filters receive a `Hash` object and expect your block to return either true
(if the file is to be removed from the result) or false (if the result should be kept).
In the above example, the filter will remove all files that match "/helpers/" in their path.

#### Array Filter

```ruby
RSpecTracer.start do
  add_filter ['/helpers/', %r{^/utils/}]
end
```

You can pass in an array containing any of the other filter types.

## Contributing

Read the [contribution guide](https://github.com/avmnu-sng/rspec-tracer/blob/main/.github/CONTRIBUTING.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Rspec Tracer project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [Code of Conduct](https://github.com/avmnu-sng/rspec-tracer/blob/main/.github/CODE_OF_CONDUCT.md).
