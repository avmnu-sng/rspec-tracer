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
# Behavioral contract:
#   - When duplicates detected AND fail_on_duplicates=true:
#       runner_hook drops every group from the run; at_exit_behavior
#       calls Kernel.exit(1) BEFORE engine.finalize fires - so NO
#       cache is written, and stderr carries the "N duplicate
#       example(s) across M identity hash(es)" error log.
#   - When duplicates detected AND fail_on_duplicates=false:
#       runner_hook still drops the colliding groups but exits 0;
#       cache (including duplicate_examples.json) IS written.
#
# Assertion shape per `feedback_v2_integration_exit_status`: cache
# state is the load-bearing check on the exit-0 path; on the exit-1
# path the cache write is intentionally skipped, so the log message
# in stderr is the load-bearing assertion.
#
# Fixture: a parameterized `.each` loop wrapping a single `it` block
# produces N examples that share example_group + description +
# full_description + file_name + line_number - which is exactly the
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
      Open3.capture2e(env, 'bundle', 'exec', 'rspec', '--no-color', 'duplicates_spec.rb',
                      chdir: dir)
    end
  end

  def read_duplicate_examples(dir)
    cache_dir = File.join(dir, 'rspec_tracer_cache')
    manifest = JSON.parse(File.read(File.join(cache_dir, 'last_run.json'), encoding: 'UTF-8'))
    run_id = manifest.fetch('run_id')
    JSON.parse(File.read(File.join(cache_dir, run_id, 'duplicate_examples.json'), encoding: 'UTF-8'))
  end

  context 'when fail_on_duplicates is true via the DSL' do
    it 'exits non-zero AND emits the duplicate-detection error log' do
      Dir.mktmpdir do |dir|
        write_fixture(dir, dsl_body: "fail_on_duplicates true\n")

        out, status = run_rspec(dir)

        expect(status.success?).to(
          be(false),
          "expected non-zero exit when fail_on_duplicates is true, got 0:\n#{out}"
        )
        expect(out).to match(duplicate_log_re)
      end
    end
  end

  context 'when fail_on_duplicates is false via the DSL' do
    it 'exits zero AND writes duplicate_examples.json with the colliding identity' do
      Dir.mktmpdir do |dir|
        write_fixture(dir, dsl_body: "fail_on_duplicates false\n")

        out, status = run_rspec(dir)

        expect(status.success?).to(
          be(true),
          "expected zero exit when fail_on_duplicates is false, got #{status.exitstatus}:\n#{out}"
        )
        duplicates = read_duplicate_examples(dir)
        expect(duplicates).not_to be_empty
        expect(duplicates.values.flatten.size).to be >= 2
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
        duplicates = read_duplicate_examples(dir)
        expect(duplicates).not_to be_empty
      end
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength
