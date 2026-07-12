# frozen_string_literal: true

# End-to-end integration for the v2 engine against the benchmark
# ruby_app fixture. Runs the fixture via subprocess and asserts that:
#
#   - the suite exits green cold and warm
#   - the 13-file cache is written under run_id/, stamped with the
#     current schema_version in last_run.json
#   - dependency + boot_set maps are populated
#
# There is no "legacy engine" path to compare against anymore -
# `use_v2_tracker` is gone and the v2 engine is the only engine. The
# previous "parity with legacy" scenarios have been retired.

require 'bundler'
require 'fileutils'
require 'json'
require 'open3'

# rubocop:disable RSpec/DescribeClass, RSpec/MultipleExpectations
RSpec.describe 'ruby_app v2 engine integration' do
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
    JSON.parse(File.read(File.join(cache_dir, 'last_run.json'), encoding: 'UTF-8'))
  end

  def load_cache_file(name)
    run_id = load_last_run_manifest.fetch('run_id')
    JSON.parse(File.read(File.join(cache_dir, run_id, name), encoding: 'UTF-8'))
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

  describe 'cold run' do
    it 'exits cleanly with the tracer banner present' do
      out, status = run_rspec

      expect(status.exitstatus).to eq(0), "cold run failed:\n#{out}"
      expect(out).to include('RSpec tracer')
    end

    it 'writes a v2 cache stamped with the current schema_version' do
      run_rspec

      expect(load_last_run_manifest['schema_version']).to eq(RSpecTracer::Storage::Schema::CURRENT)
    end

    it 'writes every FILENAMES entry under the run-id directory' do
      run_rspec

      run_id = load_last_run_manifest.fetch('run_id')
      RSpecTracer::Storage::JsonBackend::FILENAMES.each do |filename|
        expect(File).to exist(File.join(cache_dir, run_id, filename)), "missing #{filename}"
      end
    end

    it 'populates the dependency graph with non-empty entries for every run example' do
      run_rspec

      dependency = load_cache_file('dependency.json')
      expect(dependency).not_to be_empty
      expect(dependency.values).to all(be_an(Array))
    end

    it 'persists the boot_set digest map' do
      run_rspec

      boot_set = load_cache_file('boot_set.json')
      expect(boot_set).to be_a(Hash)
    end
  end

  describe 'HTML reporter output' do
    it 'emits index.html plus the committed asset bundle' do
      run_rspec

      expect(File).to exist(File.join(report_dir, 'index.html'))
      expect(File).to exist(File.join(report_dir, 'assets', 'index.js'))
      expect(File).to exist(File.join(report_dir, 'assets', 'index.css'))
    end

    it 'embeds the payload run_id matching report.json' do
      run_rspec
      report_json_run_id = JSON.parse(File.read(File.join(report_dir, 'report.json'), encoding: 'UTF-8'))['run_id']
      html = File.read(File.join(report_dir, 'index.html'), encoding: 'UTF-8')

      expect(html).to include(%("run_id":"#{report_json_run_id}"))
    end

    it 'renders server-side fallback tables so JavaScript-disabled readers see data' do
      run_rspec
      html = File.read(File.join(report_dir, 'index.html'), encoding: 'UTF-8')

      expect(html).to include('id="fallback-all-examples"')
      expect(html).not_to include('<!-- RSPEC_TRACER_FALLBACK -->')
    end
  end

  describe 'warm run' do
    it 'exits cleanly on the second run (cache round-trip works)' do
      _, cold_status = run_rspec
      warm_out, warm_status = run_rspec

      expect(cold_status.exitstatus).to eq(0)
      expect(warm_status.exitstatus).to eq(0), "warm run failed:\n#{warm_out}"
    end

    it 'keeps the run_id hex-only across warm runs' do
      run_rspec
      run_rspec

      expect(load_last_run_manifest['run_id']).to match(/\A[0-9a-f]+\z/)
    end

    it 'skips every example when nothing changed (asserts filter decisions, not just exit status)' do
      run_rspec
      all_example_ids = load_cache_file('all_examples.json').keys

      run_rspec

      expect(load_cache_file('skipped_examples.json')).to match_array(all_example_ids)
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleExpectations
