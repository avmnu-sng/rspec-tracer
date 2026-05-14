# frozen_string_literal: true

require 'spec_helper'
require 'bundler'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

# Real-user-shape integration coverage for the duplicate-example
# detection contract. Two surfaces drive the same engine path:
#
#   1. DSL path - `.rspec-tracer` calls `fail_on_duplicates true`.
#   2. ENV path - `RSPEC_TRACER_FAIL_ON_DUPLICATES=true` overrides
#      the DSL value at config-load time.
#
# Behavioral contract (rspec-tracer drops the colliding examples but
# still runs the rest of the suite - issue #210):
#   - duplicates detected, fail_on_duplicates=true:
#       the colliding examples are dropped, the non-duplicate
#       examples still run, and at_exit_behavior calls Kernel.exit(1)
#       BEFORE the cache is written - so NO cache, and the
#       "N duplicate example(s) across M identity hash(es)" error log
#       names the colliding examples.
#   - duplicates detected, fail_on_duplicates=false:
#       same prune, but the run exits 0 and the cache (including
#       duplicate_examples.json + the non-duplicate examples) IS
#       written.
#   In both cases the rspec-tracer banner reports the surviving
#   example count - the suite is NOT aborted to zero examples.
#
# Assertion shape per `feedback_v2_integration_exit_status`: the
# load-bearing checks are the exit code, the banner's surviving-
# example count, and (on the exit-0 path) the written cache.
#
# Fixture: a parameterized `.each` loop wrapping a single `it` block
# produces N examples that share example_group + description +
# full_description + shared_group + file_name - which is exactly the
# tuple `RSpecTracer::Example.from` MD5-hashes into example_id. So
# the two iterations collide on rspec-tracer's identity hash even
# though RSpec itself treats them as distinct examples.
#
# rubocop:disable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength
RSpec.describe 'fail_on_duplicates real-user-shape integration' do
  let(:project_root) { File.expand_path('../..', __dir__) }
  let(:duplicate_log_re) { /\d+ duplicate example\(s\) across \d+ identity hash/ }
  let(:gemfile_path) { File.join(project_root, 'Gemfile') }

  let(:duplicate_spec_body) do
    <<~RUBY
      RSpec.describe 'parameterized duplicates fixture' do
        [1, 2].each do |n|
          it 'computes the same identity twice' do
            expect(n).to eq(n)
          end
        end
      end

      RSpec.describe 'a non-duplicate baseline' do
        it 'runs once with a unique identity' do
          expect(true).to be(true)
        end
      end
    RUBY
  end

  def write_fixture(dir, dsl_body:)
    File.write(File.join(dir, '.rspec-tracer'), <<~RUBY)
      # frozen_string_literal: true
      RSpecTracer.configure do
        #{dsl_body}
      end
    RUBY
    File.write(File.join(dir, 'spec_helper.rb'), <<~RUBY)
      require 'rspec_tracer'
      RSpecTracer.start
    RUBY
    File.write(File.join(dir, 'duplicates_spec.rb'), <<~RUBY)
      require_relative 'spec_helper'
      #{duplicate_spec_body}
    RUBY
  end

  def run_rspec(dir, env_overrides: {})
    Bundler.with_unbundled_env do
      env = {
        'BUNDLE_GEMFILE' => gemfile_path,
        'GIT_DEFAULT_BRANCH' => nil,
        'GIT_BRANCH' => nil
      }.merge(env_overrides)
      out, status = Open3.capture2e(env, 'bundle', 'exec', 'rspec', '--no-color',
                                    'duplicates_spec.rb', chdir: dir)
      # rspec-tracer's run summary carries a non-ASCII '·'; force UTF-8
      # + scrub so callers can match against `out` regardless of the
      # parent process's default external encoding.
      [out.dup.force_encoding('UTF-8').scrub, status]
    end
  end

  def read_duplicate_examples(dir)
    cache_dir = File.join(dir, 'rspec_tracer_cache')
    manifest = JSON.parse(File.read(File.join(cache_dir, 'last_run.json'), encoding: 'UTF-8'))
    run_id = manifest.fetch('run_id')
    JSON.parse(File.read(File.join(cache_dir, run_id, 'duplicate_examples.json'), encoding: 'UTF-8'))
  end

  def read_all_examples(dir)
    cache_dir = File.join(dir, 'rspec_tracer_cache')
    manifest = JSON.parse(File.read(File.join(cache_dir, 'last_run.json'), encoding: 'UTF-8'))
    run_id = manifest.fetch('run_id')
    JSON.parse(File.read(File.join(cache_dir, run_id, 'all_examples.json'), encoding: 'UTF-8'))
  end

  context 'when fail_on_duplicates is true via the DSL' do
    it 'drops the duplicates, runs the rest, then exits non-zero with the error log' do
      Dir.mktmpdir do |dir|
        write_fixture(dir, dsl_body: "fail_on_duplicates true\n")

        out, status = run_rspec(dir)

        expect(status.success?).to(
          be(false),
          "expected non-zero exit when fail_on_duplicates is true, got 0:\n#{out}"
        )
        expect(out).to match(duplicate_log_re)
        # the non-duplicate baseline still runs - the suite is not
        # aborted to zero examples (issue #210).
        expect(out).to include('running 1 examples')
      end
    end
  end

  context 'when fail_on_duplicates is false via the DSL' do
    it 'drops the duplicates, runs + caches the rest, and exits zero' do
      Dir.mktmpdir do |dir|
        write_fixture(dir, dsl_body: "fail_on_duplicates false\n")

        out, status = run_rspec(dir)

        expect(status.success?).to(
          be(true),
          "expected zero exit when fail_on_duplicates is false, got #{status.exitstatus}:\n#{out}"
        )
        expect(out).to include('running 1 examples')
        duplicates = read_duplicate_examples(dir)
        expect(duplicates).not_to be_empty
        expect(duplicates.values.flatten.size).to be >= 2
        # the non-duplicate baseline ran and was cached; the colliding
        # examples were dropped from all_examples by deregistration.
        expect(read_all_examples(dir).size).to eq(1)
      end
    end
  end

  context 'when RSPEC_TRACER_FAIL_ON_DUPLICATES=true overrides a DSL false' do
    it 'env wins over DSL at config-load - exits non-zero despite fail_on_duplicates false' do
      Dir.mktmpdir do |dir|
        write_fixture(dir, dsl_body: "fail_on_duplicates false\n")

        out, status = run_rspec(dir, env_overrides: { 'RSPEC_TRACER_FAIL_ON_DUPLICATES' => 'true' })

        expect(status.success?).to(
          be(false),
          "expected non-zero exit when env=true overrides DSL=false, got 0:\n#{out}"
        )
        expect(out).to match(duplicate_log_re)
        expect(out).to include('running 1 examples')
      end
    end
  end

  context 'when RSPEC_TRACER_FAIL_ON_DUPLICATES=false overrides a DSL true' do
    it 'env wins over DSL at config-load - exits zero despite fail_on_duplicates true' do
      Dir.mktmpdir do |dir|
        write_fixture(dir, dsl_body: "fail_on_duplicates true\n")

        out, status = run_rspec(dir, env_overrides: { 'RSPEC_TRACER_FAIL_ON_DUPLICATES' => 'false' })

        expect(status.success?).to(
          be(true),
          "expected zero exit when env=false overrides DSL=true, got #{status.exitstatus}:\n#{out}"
        )
        expect(out).to include('running 1 examples')
        duplicates = read_duplicate_examples(dir)
        expect(duplicates).not_to be_empty
      end
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength
