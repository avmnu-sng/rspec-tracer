# frozen_string_literal: true

# End-to-end integration for parallel_tests + the M5.1 hook rework.
# Drives the benchmark ruby_app fixture via `parallel_rspec spec` in a
# subprocess, then asserts that:
#
#   - every worker exits green
#   - per-worker cache dirs are purged at exit
#   - the top-level cache has every FILENAMES entry present and sees
#     all example ids the workers observed (union-of-peers merge)
#   - the lock file is cleaned up after the last worker finishes
#   - a warm run produces a zero-re-run filter decision
#     (M4.3-style filter assertion, not just exit status)
#
# Depends on the `parallel_tests` gem being in the fixture's Gemfile.

require 'bundler'
require 'fileutils'
require 'json'
require 'open3'
require 'set'

# Module-scoped fixture constants + helpers (mirrors RailsAppSpecHelpers
# from M4.3). Keeps `let` out of the before(:all) hook that installs the
# fixture's bundle - RSpec disallows memoized accessors there.
module ParallelTestsSpecHelpers
  FIXTURE_ROOT = File.expand_path('../../benchmark/fixtures/ruby_app', __dir__)
  CACHE_ROOT = File.join(FIXTURE_ROOT, 'rspec_tracer_cache')
  REPORT_ROOT = File.join(FIXTURE_ROOT, 'rspec_tracer_report')
  COVERAGE_ROOT = File.join(FIXTURE_ROOT, 'rspec_tracer_coverage')
  LOCK_FILE = File.join(FIXTURE_ROOT, 'rspec_tracer.lock')
  SCRUB_PATHS = [CACHE_ROOT, REPORT_ROOT, COVERAGE_ROOT, LOCK_FILE].freeze

  module_function

  def ensure_bundle!
    Bundler.with_unbundled_env do
      Dir.chdir(FIXTURE_ROOT) do
        unless system('bundle', 'check', out: File::NULL, err: File::NULL)
          out, status = Open3.capture2e('bundle', 'install', '--quiet')
          raise "bundle install failed in #{FIXTURE_ROOT}:\n#{out}" unless status.success?
        end
      end
    end
  end

  def run_parallel
    Bundler.with_unbundled_env do
      Open3.capture2e({ 'PARALLEL_TEST_GROUPS' => '2' },
                      'bundle', 'exec', 'parallel_rspec', 'spec',
                      chdir: FIXTURE_ROOT)
    end
  end

  def scrub!
    FileUtils.rm_rf(SCRUB_PATHS)
  end

  def load_last_run
    JSON.parse(File.read(File.join(CACHE_ROOT, 'last_run.json'), encoding: 'UTF-8'))
  end

  def load_top_cache_file(name)
    run_id = load_last_run.fetch('run_id')
    JSON.parse(File.read(File.join(CACHE_ROOT, run_id, name), encoding: 'UTF-8'))
  end
end

# rubocop:disable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/BeforeAfterAll
RSpec.describe 'parallel_tests v2 engine integration' do
  include ParallelTestsSpecHelpers

  before(:all) { ParallelTestsSpecHelpers.ensure_bundle! }

  around do |example|
    ParallelTestsSpecHelpers.scrub!
    example.run
    ParallelTestsSpecHelpers.scrub!
  end

  describe 'cold parallel run' do
    it 'exits green with every worker completing' do
      out, status = run_parallel

      expect(status.exitstatus).to eq(0), "parallel run failed:\n#{out}"
    end

    it 'purges per-worker parallel_tests_N directories on the last worker' do
      run_parallel

      stragglers = Dir.glob(File.join(ParallelTestsSpecHelpers::CACHE_ROOT, 'parallel_tests_*'))
      expect(stragglers).to be_empty, "leftover worker dirs: #{stragglers.inspect}"
    end

    it 'writes a merged top-level snapshot with every FILENAMES entry present' do
      run_parallel

      run_id = load_last_run.fetch('run_id')
      RSpecTracer::Storage::JsonBackend::FILENAMES.each do |filename|
        expect(File).to exist(File.join(ParallelTestsSpecHelpers::CACHE_ROOT, run_id, filename)), "missing #{filename}"
      end
    end

    it 'removes the lock file once the last worker completes' do
      run_parallel

      expect(File.exist?(ParallelTestsSpecHelpers::LOCK_FILE)).to be(false)
    end

    it 'unions example ids from both workers into the top-level snapshot' do
      run_parallel

      all_examples = load_top_cache_file('all_examples.json')
      # The fixture has 3 spec files; parallel_rspec distributes them
      # across 2 workers and the merge union gathers every example.
      expect(all_examples.keys).not_to be_empty
      expect(all_examples.keys.size).to be >= 3
    end
  end

  describe 'warm parallel run' do
    it 'skips every example on the second invocation (cache round-trip via the merged snapshot)' do
      run_parallel
      cold_examples = load_top_cache_file('all_examples.json').keys

      run_parallel
      warm_skipped = load_top_cache_file('skipped_examples.json')

      expect(warm_skipped).to match_array(cold_examples)
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/BeforeAfterAll
