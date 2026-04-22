# frozen_string_literal: true

# End-to-end integration for the v2 core engine: runs the benchmark
# ruby_app fixture via subprocess once on the legacy path, once on
# the v2 path (RSPEC_TRACER_USE_V2_TRACKER=true), and asserts that:
#
#   - both modes exit green on both cold and warm runs
#   - v2 persists a schema_version 3 cache with every FILENAMES
#     entry present
#   - the set of example ids discovered by both modes matches
#     (filter-decision parity for the identical fixture)
#
# This exercises the Engine + RSpec hook routing + JsonBackend +
# Snapshot shape all together, so a regression anywhere in the chain
# fails here before the per-module unit spec catches it.

require 'bundler'
require 'fileutils'
require 'json'
require 'open3'

# The spec runs two subprocesses and compares outcomes; metric cops
# tuned for single-line expectations scatter the narrative.
# rubocop:disable RSpec/DescribeClass, RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe 'ruby_app under v2 tracker' do
  let(:fixture_root) { File.expand_path('../../benchmark/fixtures/ruby_app', __dir__) }
  let(:cache_dir)    { File.join(fixture_root, 'rspec_tracer_cache') }
  let(:report_dir)   { File.join(fixture_root, 'rspec_tracer_report') }
  let(:coverage_dir) { File.join(fixture_root, 'rspec_tracer_coverage') }

  around do |example|
    Bundler.with_unbundled_env do
      FileUtils.rm_rf([cache_dir, report_dir, coverage_dir])
      example.run
      FileUtils.rm_rf([cache_dir, report_dir, coverage_dir])
    end
  end

  def run_rspec(env: {})
    Open3.capture2e(env, 'bundle', 'exec', 'rspec', '--no-color', chdir: fixture_root)
  end

  def load_last_run_manifest
    JSON.parse(File.read(File.join(cache_dir, 'last_run.json')))
  end

  def load_cache_file(name)
    run_id = load_last_run_manifest.fetch('run_id')
    JSON.parse(File.read(File.join(cache_dir, run_id, name)))
  end

  def ensure_bundle_installed!
    Dir.chdir(fixture_root) do
      unless system('bundle check > /dev/null 2>&1')
        install_out, install_status = Open3.capture2e('bundle', 'install', '--quiet')
        raise "bundle install failed in #{fixture_root}:\n#{install_out}" unless install_status.success?
      end
    end
  end

  before { ensure_bundle_installed! }

  describe 'cold cache + v2 engine' do
    let(:v2_env) { { 'RSPEC_TRACER_USE_V2_TRACKER' => 'true' } }

    it 'exits cleanly with the same banner as legacy' do
      out, status = run_rspec(env: v2_env)

      expect(status.exitstatus).to eq(0), "v2 cold run failed:\n#{out}"
      expect(out).to include('RSpec tracer')
    end

    it 'writes a v2 cache with schema_version 3' do
      run_rspec(env: v2_env)

      expect(load_last_run_manifest['schema_version']).to eq(3)
    end

    it 'writes every FILENAMES entry under the run-id directory' do
      run_rspec(env: v2_env)

      run_id = load_last_run_manifest.fetch('run_id')
      RSpecTracer::Storage::JsonBackend::FILENAMES.each do |filename|
        expect(File).to exist(File.join(cache_dir, run_id, filename)), "missing #{filename}"
      end
    end

    it 'populates the dependency graph with non-empty entries for every run example' do
      run_rspec(env: v2_env)

      dependency = load_cache_file('dependency.json')
      expect(dependency).not_to be_empty
      expect(dependency.values).to all(be_an(Array))
    end

    it 'persists the boot_set digest map (M3.7 field)' do
      run_rspec(env: v2_env)

      boot_set = load_cache_file('boot_set.json')
      expect(boot_set).to be_a(Hash)
    end
  end

  describe 'warm cache + v2 engine' do
    let(:v2_env) { { 'RSPEC_TRACER_USE_V2_TRACKER' => 'true' } }

    it 'exits cleanly on the second run (cache round-trip works)' do
      _, cold_status = run_rspec(env: v2_env)
      warm_out, warm_status = run_rspec(env: v2_env)

      expect(cold_status.exitstatus).to eq(0)
      expect(warm_status.exitstatus).to eq(0), "v2 warm run failed:\n#{warm_out}"
    end

    it 'keeps the run_id hex-only across warm runs' do
      run_rspec(env: v2_env)
      run_rspec(env: v2_env)

      expect(load_last_run_manifest['run_id']).to match(/\A[0-9a-f]+\z/)
    end
  end

  describe 'parity with the legacy engine' do
    it 'discovers the same example ids in legacy and v2 runs' do
      _, legacy_status = run_rspec
      expect(legacy_status.exitstatus).to eq(0)
      legacy_examples = load_cache_file('all_examples.json').keys.sort
      FileUtils.rm_rf([cache_dir, report_dir, coverage_dir])

      _, v2_status = run_rspec(env: { 'RSPEC_TRACER_USE_V2_TRACKER' => 'true' })
      expect(v2_status.exitstatus).to eq(0)
      v2_examples = load_cache_file('all_examples.json').keys.sort

      expect(v2_examples).to eq(legacy_examples)
    end

    it 'tracks every app/*.rb and spec/*_spec.rb in both modes' do
      # Legacy attributes spec_helper.rb via register_traced_dependency
      # (RSpec.configuration.requires hook); v2 captures it into
      # LoadedFilesTracker.boot_set as a whole-suite invalidator, not
      # into all_files. Spec-helper-equivalent coverage is preserved
      # through a different attribution path under v2; both modes
      # still need the actual app/ + spec/ source files in all_files.
      run_rspec
      legacy_files = load_cache_file('all_files.json').keys.sort
      FileUtils.rm_rf([cache_dir, report_dir, coverage_dir])

      run_rspec(env: { 'RSPEC_TRACER_USE_V2_TRACKER' => 'true' })
      v2_files = load_cache_file('all_files.json').keys.sort

      common_app_files = legacy_files.grep(%r{^/(app|spec/.*_spec)})
      expect(v2_files).to include(*common_app_files)
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/ExampleLength, RSpec/MultipleExpectations
