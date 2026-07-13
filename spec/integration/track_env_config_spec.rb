# frozen_string_literal: true

# End-to-end integration for the config-level `track_env(*names)`
# DSL + wildcard env matching. Drives the reference Rails fixture at
# `spec/fixtures/rails_app/` via subprocess RSpec.
#
# This spec is config-level only; per-example wildcard coverage lives
# in `per_example_dsl_spec.rb`. The fixture's `.rspec-tracer` is
# rewritten per-example here (config-level DSL is the surface under
# test) and restored in `after`.
#
# Assertion philosophy matches the other integration specs: assert
# on the set of examples that re-ran (filter decisions), not exit
# status; exit-status-only checks mask cache-persistence bugs.

require 'bundler'
require 'fileutils'
require 'json'
require 'open3'
require 'set'

module TrackEnvConfigSpecHelpers
  FIXTURE_ROOT = File.expand_path('../fixtures/rails_app', __dir__)
  CACHE_DIR = File.join(FIXTURE_ROOT, 'rspec_tracer_cache')
  COVERAGE_DIR = File.join(FIXTURE_ROOT, 'rspec_tracer_coverage')
  REPORT_DIR = File.join(FIXTURE_ROOT, 'rspec_tracer_report')
  LOCAL_COVERAGE = File.join(FIXTURE_ROOT, 'coverage')
  TRACER_ENV = { 'RSPEC_TRACER' => '1' }.freeze
  SCRUB_DIRS = [CACHE_DIR, COVERAGE_DIR, REPORT_DIR, LOCAL_COVERAGE].freeze
  RSPEC_TRACER_CONFIG = File.join(FIXTURE_ROOT, '.rspec-tracer')

  module_function

  def run_rspec_in_fixture(env = {})
    Bundler.with_unbundled_env do
      Open3.capture2e(TRACER_ENV.merge(env), 'bundle', 'exec', 'rspec', '--no-color',
                      chdir: FIXTURE_ROOT)
    end
  end

  def ensure_bundle_and_db
    Bundler.with_unbundled_env do
      Dir.chdir(FIXTURE_ROOT) do
        gemfile_env = { 'BUNDLE_GEMFILE' => File.join(FIXTURE_ROOT, 'Gemfile') }
        unless system(gemfile_env, 'bundle', 'check', out: File::NULL, err: File::NULL)
          system(gemfile_env, 'bundle', 'install', '--quiet') || raise('bundle install failed')
        end

        system('bundle', 'exec', 'rails', 'db:test:prepare',
               out: File::NULL, err: File::NULL) || raise('db:test:prepare failed')
      end
    end
  end

  def clear_tracer_state
    FileUtils.rm_rf(SCRUB_DIRS)
  end

  def load_cache_file(name)
    manifest = JSON.parse(File.read(File.join(CACHE_DIR, 'last_run.json')))
    JSON.parse(File.read(File.join(CACHE_DIR, manifest.fetch('run_id'), name)))
  end

  def re_run_example_ids
    all_examples = load_cache_file('all_examples.json')
    skipped = load_cache_file('skipped_examples.json')
    (all_examples.keys - skipped.to_a).to_set
  end
end

# rubocop:disable RSpec/DescribeClass, RSpec/InstanceVariable, RSpec/BeforeAfterAll
# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe 'config-level track_env DSL integration' do
  include TrackEnvConfigSpecHelpers

  before(:all) { TrackEnvConfigSpecHelpers.ensure_bundle_and_db }

  let(:original_config) { File.read(TrackEnvConfigSpecHelpers::RSPEC_TRACER_CONFIG) }

  before do
    @original_config = original_config
    TrackEnvConfigSpecHelpers.clear_tracer_state
  end

  after do
    File.write(TrackEnvConfigSpecHelpers::RSPEC_TRACER_CONFIG, @original_config)
    TrackEnvConfigSpecHelpers.clear_tracer_state
  end

  describe 'literal config-level env name' do
    before do
      File.write(TrackEnvConfigSpecHelpers::RSPEC_TRACER_CONFIG, <<~CONFIG)
        # frozen_string_literal: true
        RSpecTracer.configure do
          track_env 'AUTH_TOKEN'
        end
      CONFIG
    end

    it 're-runs every previously-seen example when AUTH_TOKEN flips between runs' do
      cold_out, cold_status = TrackEnvConfigSpecHelpers.run_rspec_in_fixture('AUTH_TOKEN' => 'v1')
      raise "cold run failed:\n#{cold_out}" unless cold_status.success?

      cold_env_snapshot = TrackEnvConfigSpecHelpers.load_cache_file('env_snapshot.json')
      expect(cold_env_snapshot).to have_key('AUTH_TOKEN')

      warm_out, warm_status = TrackEnvConfigSpecHelpers.run_rspec_in_fixture('AUTH_TOKEN' => 'v2')
      raise "warm run failed:\n#{warm_out}" unless warm_status.success?

      skipped = TrackEnvConfigSpecHelpers.load_cache_file('skipped_examples.json')
      all_examples = TrackEnvConfigSpecHelpers.load_cache_file('all_examples.json')

      expect(skipped).to eq([])
      expect(all_examples).not_to be_empty
    end

    it 'updates env_snapshot to the new digest on warm run' do
      _, cold_status = TrackEnvConfigSpecHelpers.run_rspec_in_fixture('AUTH_TOKEN' => 'v1')
      raise 'cold run failed' unless cold_status.success?

      cold_env_snapshot = TrackEnvConfigSpecHelpers.load_cache_file('env_snapshot.json')

      _, warm_status = TrackEnvConfigSpecHelpers.run_rspec_in_fixture('AUTH_TOKEN' => 'v2')
      raise 'warm run failed' unless warm_status.success?

      warm_env_snapshot = TrackEnvConfigSpecHelpers.load_cache_file('env_snapshot.json')

      expect(warm_env_snapshot['AUTH_TOKEN']).not_to eq(cold_env_snapshot['AUTH_TOKEN'])
    end
  end

  describe 'wildcard config-level pattern' do
    before do
      File.write(TrackEnvConfigSpecHelpers::RSPEC_TRACER_CONFIG, <<~CONFIG)
        # frozen_string_literal: true
        RSpecTracer.configure do
          track_env 'M53_PROBE_*'
        end
      CONFIG
    end

    it 'persists wildcard-expanded concrete keys in env_snapshot.json (no pattern leakage)' do
      out, status = TrackEnvConfigSpecHelpers.run_rspec_in_fixture(
        'M53_PROBE_ONE' => 'a', 'M53_PROBE_TWO' => 'b', 'UNRELATED_KEY' => 'z'
      )
      raise "run failed:\n#{out}" unless status.success?

      env_snapshot = TrackEnvConfigSpecHelpers.load_cache_file('env_snapshot.json')

      expect(env_snapshot.keys).to include('M53_PROBE_ONE', 'M53_PROBE_TWO')
      expect(env_snapshot.keys).not_to include('M53_PROBE_*', 'UNRELATED_KEY')
    end

    it 're-runs every previously-seen example when a wildcard-matched key flips' do
      _, cold_status = TrackEnvConfigSpecHelpers.run_rspec_in_fixture(
        'M53_PROBE_ONE' => 'v1', 'M53_PROBE_TWO' => 'v1'
      )
      raise 'cold run failed' unless cold_status.success?

      _, warm_status = TrackEnvConfigSpecHelpers.run_rspec_in_fixture(
        'M53_PROBE_ONE' => 'v1', 'M53_PROBE_TWO' => 'v2'
      )
      raise 'warm run failed' unless warm_status.success?

      skipped = TrackEnvConfigSpecHelpers.load_cache_file('skipped_examples.json')
      all_examples = TrackEnvConfigSpecHelpers.load_cache_file('all_examples.json')

      expect(skipped).to eq([])
      expect(all_examples).not_to be_empty
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/InstanceVariable, RSpec/BeforeAfterAll
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
