# frozen_string_literal: true

# M8.2-B narrow-AR-schema integration spec. Drives the rails fixture
# (spec/fixtures/rails_app/spec/narrow_schema_spec.rb) under
# RSPEC_TRACER_RAILS_TRANSACTIONAL=false (M8.2-shipped env toggle in
# the fixture rails_helper.rb). With transactional fixtures off,
# rspec-tracer's per-example schema-subscriber attribution path
# (lib/rspec_tracer/rails/notifications.rb #record_ar_schema) becomes
# the only mechanism observing AR schema changes - the canonical use
# case for users who run integration tests with each example
# committing to the test DB.
#
# Two assertions:
#
#   1. (cold) Only the AR-touching example has db/schema.rb in its
#      dependency set. The pure-compute example does NOT - the
#      sql.active_record subscriber never fired for it.
#
#   2. (warm) After mutating db/schema.rb, the warm filter re-runs
#      only the AR-touching example. The pure-compute example stays
#      skipped, proving narrow attribution is load-bearing for the
#      filter decision (and not just a cosmetic field on the cache).
#
# Per-example commit cleanup: sequence-based unique factories
# (Time.now.to_f + pid suffix on User.email). DatabaseCleaner was
# rejected in M8.2-B because its TRUNCATE / DELETE queries fire
# sql.active_record events INSIDE the per-example bucket, which
# would attribute db/schema.rb to every example via the subscriber -
# defeating the very narrow-attribution behavior under test. Decision
# revised from kickoff (d-i DatabaseCleaner) to (d-ii sequence
# factories) once empirical evidence showed (d-i) was incompatible.

require 'bundler'
require 'fileutils'
require 'json'
require 'open3'
require 'set'

# Module-scoped constants + helpers (mirrors RailsAppSpecHelpers from
# M4.3). Keeps `let` out of before(:all) where RSpec disallows
# memoized accessors.
module NarrowArSchemaSpecHelpers
  FIXTURE_ROOT = File.expand_path('../fixtures/rails_app', __dir__)
  CACHE_DIR = File.join(FIXTURE_ROOT, 'rspec_tracer_cache')
  COVERAGE_DIR = File.join(FIXTURE_ROOT, 'rspec_tracer_coverage')
  REPORT_DIR = File.join(FIXTURE_ROOT, 'rspec_tracer_report')
  LOCAL_COVERAGE = File.join(FIXTURE_ROOT, 'coverage')
  TRACER_ENV = {
    'RSPEC_TRACER' => '1',
    'RSPEC_TRACER_RAILS_TRANSACTIONAL' => 'false'
  }.freeze
  SCRUB_DIRS = [CACHE_DIR, COVERAGE_DIR, REPORT_DIR, LOCAL_COVERAGE].freeze
  NARROW_SPEC = 'spec/narrow_schema_spec.rb'
  SCHEMA_FILE_NAME = '/db/schema.rb'

  MUTATION_MARKER = "\n# rspec-tracer M8.2-B narrow-schema mutation marker\n"

  module_function

  def run_rspec_in_fixture
    Bundler.with_unbundled_env do
      Open3.capture2e(TRACER_ENV, 'bundle', 'exec', 'rspec', '--no-color', NARROW_SPEC,
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
    manifest = JSON.parse(File.read(File.join(CACHE_DIR, 'last_run.json'), encoding: 'UTF-8'))
    JSON.parse(File.read(File.join(CACHE_DIR, manifest.fetch('run_id'), name), encoding: 'UTF-8'))
  end
end

# rubocop:disable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/BeforeAfterAll, RSpec/InstanceVariable, RSpec/ExampleLength
RSpec.describe 'narrow AR schema attribution' do
  include NarrowArSchemaSpecHelpers

  before(:all) do
    NarrowArSchemaSpecHelpers.ensure_bundle_and_db
  end

  before do
    NarrowArSchemaSpecHelpers.clear_tracer_state
    out, status = NarrowArSchemaSpecHelpers.run_rspec_in_fixture
    raise "cold rspec failed (status=#{status.exitstatus}):\n#{out}" unless status.success?

    @all_examples = NarrowArSchemaSpecHelpers.load_cache_file('all_examples.json')
    @reverse_dependency = NarrowArSchemaSpecHelpers.load_cache_file('reverse_dependency.json')
  end

  after(:all) do
    NarrowArSchemaSpecHelpers.clear_tracer_state
  end

  def example_id_matching(description_substring)
    pair = @all_examples.find { |_, meta| meta['description'].to_s.include?(description_substring) }
    raise "no example matching #{description_substring.inspect} in cold cache" if pair.nil?

    pair.first
  end

  describe 'cold attribution' do
    it 'attributes db/schema.rb only to the AR-touching example' do
      ar_id = example_id_matching('creates a user')
      pure_id = example_id_matching('does not touch AR')
      schema_dependents = @reverse_dependency.fetch(NarrowArSchemaSpecHelpers::SCHEMA_FILE_NAME, []).to_set

      schema_file = NarrowArSchemaSpecHelpers::SCHEMA_FILE_NAME
      expect(schema_dependents).to(include(ar_id),
                                   "expected #{ar_id.inspect} to depend on #{schema_file}, " \
                                   "got dependents: #{schema_dependents.to_a.inspect}")
      expect(schema_dependents).not_to(include(pure_id),
                                       "pure-compute example #{pure_id.inspect} should not depend on schema; " \
                                       "got dependents: #{schema_dependents.to_a.inspect}")
    end
  end

  describe 'warm filter after schema mutation' do
    it 're-runs only the AR-touching example' do
      ar_id = example_id_matching('creates a user')
      pure_id = example_id_matching('does not touch AR')
      schema_path = File.join(NarrowArSchemaSpecHelpers::FIXTURE_ROOT, 'db/schema.rb')
      original = File.binread(schema_path)
      File.open(schema_path, 'ab') { |f| f.write(NarrowArSchemaSpecHelpers::MUTATION_MARKER) }

      begin
        out, status = NarrowArSchemaSpecHelpers.run_rspec_in_fixture
        raise "warm rspec failed (status=#{status.exitstatus}):\n#{out}" unless status.success?

        skipped = NarrowArSchemaSpecHelpers.load_cache_file('skipped_examples.json').to_set
        expect(skipped).to(include(pure_id),
                           "pure-compute example #{pure_id.inspect} should be skipped on warm; " \
                           "got skipped: #{skipped.to_a.inspect}")
        expect(skipped).not_to(include(ar_id),
                               "AR-touching example #{ar_id.inspect} should re-run on schema change; " \
                               "got skipped: #{skipped.to_a.inspect}")
      ensure
        File.binwrite(schema_path, original)
      end
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/BeforeAfterAll, RSpec/InstanceVariable, RSpec/ExampleLength
