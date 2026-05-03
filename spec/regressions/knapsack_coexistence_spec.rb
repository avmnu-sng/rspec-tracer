# frozen_string_literal: true

# M8.10: knapsack composition smoke spec.
#
# knapsack (https://github.com/KnapsackPro/knapsack) is the dominant
# free test-splitter on production Rails CI - it pre-filters which
# spec files run on each CI node so the suite parallelizes across
# machines. M9.0 shipped coexistence smokes for rspec-retry +
# rspec-rerun (which prepend RSpec::Core::Example / register a
# Formatter); knapsack hooks into RSpec.configure callbacks +
# logs example timings. Different surface from retry/rerun but the
# same composition concern: rspec-tracer's RunnerHook prepends
# RSpec::Core::Runner; the two should coexist without raise.
#
# Smoke contract:
#   1. Both gems load alongside each other without raising at boot.
#   2. A knapsack-bound rspec subprocess with rspec-tracer also
#      active completes the run.
#   3. The rspec-tracer cache writes successfully (run_id manifest
#      + all_examples.json present after the run).
#
# Drives a subprocess inside `Bundler.with_unbundled_env` + a tmpdir
# CWD so the inline test specs don't pollute the project's
# rspec_tracer_cache + the outer rspec process never loads
# knapsack's RSpec.configure side-effects (which would otherwise
# affect every subsequent in-process spec). The outer Gemfile
# carries knapsack in the :development group (require: false default)
# so the subprocess can require it on demand.
#
# Per `feedback_v2_integration_exit_status`: the cache-state
# assertion (not just exit-status) is the load-bearing check.
#
require 'bundler'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

# rubocop:disable RSpec/DescribeClass, RSpec/MultipleExpectations
# rubocop:disable RSpec/ExampleLength
RSpec.describe 'knapsack coexistence (smoke; M8.10)' do
  let(:project_root) { File.expand_path('../..', __dir__) }
  let(:gemfile_path) { File.join(project_root, 'Gemfile') }

  let(:inline_spec_body) do
    <<~RUBY
      require "rspec_tracer"
      RSpecTracer.start

      require "knapsack"
      Knapsack::Adapters::RspecAdapter.bind

      RSpec.describe "knapsack composes with rspec-tracer" do
        it "passes alongside knapsack's RSpec.configure hooks" do
          expect(true).to be(true)
        end

        it "exercises a second example for cache + dependency tracking" do
          expect(2 + 2).to eq(4)
        end
      end
    RUBY
  end

  it 'loads both gems without raising and writes a usable rspec-tracer cache' do
    Dir.mktmpdir do |dir|
      spec_path = File.join(dir, 'knapsack_smoke_spec.rb')
      File.write(spec_path, inline_spec_body)

      # knapsack's after(:suite) hook reads `knapsack_rspec_report.json`
      # to compare per-example timings against the saved baseline. On
      # first run the file doesn't exist; pre-creating an empty
      # report keeps the smoke focused on COMPOSITION (does
      # rspec-tracer + knapsack load + run cleanly?) rather than on
      # knapsack's own bootstrap ceremony. Per
      # feedback_v2_integration_exit_status the load-bearing
      # assertion is the cache-state, but we still want a clean
      # exit so the smoke is unambiguous.
      File.write(File.join(dir, 'knapsack_rspec_report.json'), '{}')

      out, status = Bundler.with_unbundled_env do
        env = {
          'BUNDLE_GEMFILE' => gemfile_path,
          'KNAPSACK_TEST_FILE_PATTERN' => nil
        }
        Open3.capture2e(env, 'bundle', 'exec', 'rspec', '--no-color', spec_path,
                        chdir: dir)
      end

      expect(status.success?).to(
        be(true),
        "knapsack coexistence subprocess failed (exit=#{status.exitstatus}):\n#{out}"
      )

      cache_dir = File.join(dir, 'rspec_tracer_cache')
      manifest_path = File.join(cache_dir, 'last_run.json')
      expect(File).to(
        exist(manifest_path),
        "expected rspec-tracer cache manifest at #{manifest_path}; got: " \
        "#{Dir.exist?(cache_dir) ? Dir.children(cache_dir).inspect : '(no cache dir)'}"
      )

      manifest = JSON.parse(File.read(manifest_path))
      run_id = manifest.fetch('run_id')
      all_examples = JSON.parse(File.read(File.join(cache_dir, run_id, 'all_examples.json')))

      expect(all_examples.size).to(
        eq(2),
        "expected 2 registered examples, got #{all_examples.size}: " \
        "#{all_examples.values.map { |m| m['description'] }.inspect}"
      )
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleExpectations
# rubocop:enable RSpec/ExampleLength
