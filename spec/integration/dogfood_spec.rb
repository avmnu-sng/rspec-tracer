# frozen_string_literal: true

# Dogfooding: run rspec-tracer against a trivial sample project (the
# benchmark ruby_app fixture) via subprocess and assert the basic
# cold-then-warm behaviour. This is the "our gem runs our gem's tests"
# smoke test — the ultimate integration check.
#
# Reuses `benchmark/fixtures/ruby_app/`: M2.4 already built a self-
# contained fixture with tracer wired in, so M2.5 points at it rather
# than duplicating the same 3 app files + 3 spec files under
# `spec/fixtures/`.

require 'bundler'
require 'fileutils'
require 'json'
require 'open3'

# Integration spec — a single cold+warm scenario is one logical unit of
# work, not several examples. Splitting to satisfy rspec-rubocop metric
# cops would scatter the sequential narrative across unrelated `it`
# blocks without clarifying anything.
# rubocop:disable RSpec/DescribeClass, RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe 'rspec-tracer dogfood' do
  let(:fixture_root) { File.expand_path('../../benchmark/fixtures/ruby_app', __dir__) }
  let(:cache_dir)    { File.join(fixture_root, 'rspec_tracer_cache') }
  let(:report_dir)   { File.join(fixture_root, 'rspec_tracer_report') }
  let(:coverage_dir) { File.join(fixture_root, 'rspec_tracer_coverage') }

  around do |example|
    Bundler.with_unbundled_env do
      FileUtils.rm_rf([cache_dir, report_dir, coverage_dir])
      example.run
      # Leave artifacts in place for debugging; they're gitignored in the
      # fixture, and the next test invocation cleans them before running.
    end
  end

  def run_rspec_in_fixture(dir)
    Open3.capture2e('bundle', 'exec', 'rspec', '--no-color', chdir: dir)
  end

  def last_run_id(cache_dir)
    JSON.parse(File.read(File.join(cache_dir, 'last_run.json'))).fetch('run_id')
  end

  it 'runs green cold and warm, and produces a reusable cache' do
    # Ensure the fixture has its bundle installed; skip bundle install if
    # it's already satisfied.
    Dir.chdir(fixture_root) do
      unless system('bundle check > /dev/null 2>&1')
        install_out, install_status = Open3.capture2e('bundle', 'install', '--quiet')
        raise "bundle install failed in #{fixture_root}:\n#{install_out}" unless install_status.success?
      end
    end

    cold_out, cold_status = run_rspec_in_fixture(fixture_root)
    expect(cold_status.exitstatus).to eq(0), "cold run failed:\n#{cold_out}"
    expect(File).to exist(File.join(cache_dir, 'last_run.json'))
    expect(last_run_id(cache_dir)).to match(/\A[0-9a-f]+\z/)

    warm_out, warm_status = run_rspec_in_fixture(fixture_root)
    expect(warm_status.exitstatus).to eq(0), "warm run failed:\n#{warm_out}"
    expect(File).to exist(File.join(cache_dir, 'last_run.json'))
    expect(last_run_id(cache_dir)).to match(/\A[0-9a-f]+\z/)
    # Warm run prints tracer-authored output to STDOUT (skipped/cached
    # examples, summary line). Exact content varies by version, but the
    # "RSpec tracer" banner always appears.
    expect(warm_out).to include('RSpec tracer')
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/ExampleLength, RSpec/MultipleExpectations
