# frozen_string_literal: true

# End-to-end integration for parallel_tests + the M5.1 hook rework.
# Drives the benchmark ruby_app fixture via `parallel_rspec spec` in a
# subprocess and asserts that:
#
#   - every worker exits green
#   - per-worker cache dirs are purged at exit
#   - the top-level cache has every FILENAMES entry present and sees
#     all example ids the workers observed (union-of-peers merge)
#   - the lock file is cleaned up after the last worker finishes
#   - a warm run produces a zero-re-run filter decision
#     (M4.3-style filter assertion, not just exit status)
#
# Design: runs `parallel_rspec` exactly twice (cold + warm) in
# `before(:all)` and captures stdout/status + on-disk artifacts into
# class instance vars. The `it` blocks are pure inspections - no
# subprocess churn. This keeps CI exposure to the known-flaky
# "repeated parallel_rspec on GHA 2-CPU runners" surface at 2
# invocations per test file (same as the pre-M5.1 cucumber scenario).
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
    JSON.parse(File.read(File.join(CACHE_ROOT, 'last_run.json')))
  end

  def load_top_cache_file(name)
    run_id = load_last_run.fetch('run_id')
    JSON.parse(File.read(File.join(CACHE_ROOT, run_id, name)))
  end
end

# rubocop:disable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/BeforeAfterAll, RSpec/InstanceVariable
RSpec.describe 'parallel_tests v2 engine integration' do
  include ParallelTestsSpecHelpers

  before(:all) do
    ParallelTestsSpecHelpers.ensure_bundle!
    ParallelTestsSpecHelpers.scrub!

    @cold_out, @cold_status = ParallelTestsSpecHelpers.run_parallel
    raise "cold parallel_rspec failed:\n#{@cold_out}" unless @cold_status.success?

    # Capture cold-run disk state *before* the warm run overwrites it.
    @cold_run_id = ParallelTestsSpecHelpers.load_last_run.fetch('run_id')
    @cold_worker_dir_stragglers = Dir.glob(File.join(ParallelTestsSpecHelpers::CACHE_ROOT, 'parallel_tests_*'))
    @cold_lock_present = File.exist?(ParallelTestsSpecHelpers::LOCK_FILE)
    @cold_all_examples = ParallelTestsSpecHelpers.load_top_cache_file('all_examples.json')
    @cold_files_present = RSpecTracer::Storage::JsonBackend::FILENAMES.to_h do |filename|
      [filename, File.exist?(File.join(ParallelTestsSpecHelpers::CACHE_ROOT, @cold_run_id, filename))]
    end

    @warm_out, @warm_status = ParallelTestsSpecHelpers.run_parallel
    raise "warm parallel_rspec failed:\n#{@warm_out}" unless @warm_status.success?

    @warm_skipped_examples = ParallelTestsSpecHelpers.load_top_cache_file('skipped_examples.json')
  end

  after(:all) { ParallelTestsSpecHelpers.scrub! }

  describe 'cold parallel run' do
    it 'exits green with every worker completing' do
      expect(@cold_status.exitstatus).to eq(0), "cold parallel_rspec failed:\n#{@cold_out}"
    end

    it 'purges per-worker parallel_tests_N directories on the last worker' do
      expect(@cold_worker_dir_stragglers).to(be_empty,
                                             "leftover worker dirs: #{@cold_worker_dir_stragglers.inspect}")
    end

    it 'writes a merged top-level snapshot with every FILENAMES entry present' do
      missing = @cold_files_present.reject { |_, present| present }.keys
      expect(missing).to be_empty, "missing files: #{missing.inspect}"
    end

    it 'removes the lock file once the last worker completes' do
      expect(@cold_lock_present).to be(false)
    end

    it 'unions example ids from both workers into the top-level snapshot' do
      # The fixture has 3 spec files; parallel_rspec distributes them
      # across 2 workers and the merge union gathers every example.
      expect(@cold_all_examples.keys).not_to be_empty
      expect(@cold_all_examples.keys.size).to be >= 3
    end
  end

  describe 'warm parallel run' do
    it 'skips every example on the second invocation (cache round-trip via the merged snapshot)' do
      expect(@warm_skipped_examples).to match_array(@cold_all_examples.keys)
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/BeforeAfterAll, RSpec/InstanceVariable
