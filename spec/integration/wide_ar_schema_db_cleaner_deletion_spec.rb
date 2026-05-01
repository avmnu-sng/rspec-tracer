# frozen_string_literal: true

# M9.0 widening-assertion spec for the
# `DatabaseCleaner :deletion` strategy in an around hook.
#
# Real-user setup under test: a Rails project running the rspec-tracer
# `track_ar_schema_notifications` DSL with `use_transactional_fixtures
# = false` and `database_cleaner-active_record` configured for
# :deletion cleanup in a `config.around { DatabaseCleaner.cleaning
# { ... } }` block. The DELETE queries the cleaner emits between
# examples fire `sql.active_record` events INSIDE the per-example
# bucket window, so the schema-subscriber attributes db/schema.rb to
# every example wrapped by the cleaner. Same widening shape as the
# :truncation strategy, different SQL.
#
# Three assertions:
#   1. (cold) db/schema.rb is in the dependency set of every
#      AR-touching example.
#   2. (warm, schema mutated) Every AR-touching example re-runs.
#   3. (warm, schema mutated) The pure-compute describe - which opts
#      out of the `:db_cleaned` metadata so the around hook skips it -
#      does NOT re-run. The widening is bounded by DBC-wrapped
#      lifecycles, not unconditional.

require 'bundler'
require 'open3'
require 'set'

require_relative '../support/fixture_bundle_helper'

module WideArSchemaDbCleanerDeletionSpecHelpers
  TRACER_ENV = {
    'RSPEC_TRACER' => '1',
    'RSPEC_TRACER_RAILS_TRANSACTIONAL' => 'false',
    'RSPEC_TRACER_DB_CLEANER_STRATEGY' => 'deletion'
  }.freeze
  SUBPROCESS_BUNDLE_ENV = { 'BUNDLE_FROZEN' => '1' }.freeze
  WIDE_SPEC = 'spec/wide_schema_spec.rb'
  SCHEMA_FILE_NAME = '/db/schema.rb'

  MUTATION_MARKER = "\n# rspec-tracer M9.0 wide-schema mutation marker\n"

  AR_DESCRIPTIONS = ['creates user A', 'creates user B', 'creates user C and counts'].freeze
  PURE_DESCRIPTION = 'performs only pure-Ruby computation'

  module_function

  def run_rspec_in_fixture
    Bundler.with_unbundled_env do
      Open3.capture2e(TRACER_ENV.merge(SUBPROCESS_BUNDLE_ENV),
                      'bundle', 'exec', 'rspec', '--no-color', WIDE_SPEC,
                      chdir: FixtureBundleHelper::FIXTURE_ROOT)
    end
  end

  def example_id_matching(all_examples, description_substring)
    pair = all_examples.find { |_, meta| meta['description'].to_s.include?(description_substring) }
    raise "no example matching #{description_substring.inspect} in cold cache" if pair.nil?

    pair.first
  end
end

# rubocop:disable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/BeforeAfterAll, RSpec/InstanceVariable, RSpec/ExampleLength
RSpec.describe 'wide AR schema attribution under DatabaseCleaner :deletion' do
  include WideArSchemaDbCleanerDeletionSpecHelpers

  before(:all) do
    FixtureBundleHelper.ensure_bundle_and_db
    FixtureBundleHelper.clear_tracer_state

    out, status = WideArSchemaDbCleanerDeletionSpecHelpers.run_rspec_in_fixture
    raise "cold rspec failed (status=#{status.exitstatus}):\n#{out}" unless status.success?

    @cold_all_examples = FixtureBundleHelper.load_cache_file('all_examples.json')
    @cold_reverse_dependency = FixtureBundleHelper.load_cache_file('reverse_dependency.json')

    @ar_ids = WideArSchemaDbCleanerDeletionSpecHelpers::AR_DESCRIPTIONS.to_set do |desc|
      WideArSchemaDbCleanerDeletionSpecHelpers.example_id_matching(@cold_all_examples, desc)
    end
    @pure_id = WideArSchemaDbCleanerDeletionSpecHelpers.example_id_matching(
      @cold_all_examples, WideArSchemaDbCleanerDeletionSpecHelpers::PURE_DESCRIPTION
    )
  end

  after(:all) do
    FixtureBundleHelper.clear_tracer_state
  end

  describe 'cold attribution' do
    it 'attributes db/schema.rb to every AR-touching example' do
      schema_dependents = @cold_reverse_dependency
        .fetch(WideArSchemaDbCleanerDeletionSpecHelpers::SCHEMA_FILE_NAME, [])
        .to_set

      missing = @ar_ids - schema_dependents
      expect(missing).to(be_empty,
                         "AR-touching examples missing schema attribution: #{missing.to_a.inspect}; " \
                         "schema dependents: #{schema_dependents.to_a.inspect}")
    end

    it 'does NOT attribute db/schema.rb to the pure-compute example' do
      schema_dependents = @cold_reverse_dependency
        .fetch(WideArSchemaDbCleanerDeletionSpecHelpers::SCHEMA_FILE_NAME, [])
        .to_set

      expect(schema_dependents).not_to(include(@pure_id),
                                       "pure-compute example #{@pure_id.inspect} should not depend on schema; " \
                                       "got dependents: #{schema_dependents.to_a.inspect}")
    end
  end

  describe 'warm filter after schema mutation' do
    it 're-runs every AR-touching example and skips the pure-compute one' do
      schema_path = File.join(FixtureBundleHelper::FIXTURE_ROOT, 'db/schema.rb')
      original = File.binread(schema_path)
      File.open(schema_path, 'ab') { |f| f.write(WideArSchemaDbCleanerDeletionSpecHelpers::MUTATION_MARKER) }

      begin
        out, status = WideArSchemaDbCleanerDeletionSpecHelpers.run_rspec_in_fixture
        raise "warm rspec failed (status=#{status.exitstatus}):\n#{out}" unless status.success?

        skipped = FixtureBundleHelper.load_cache_file('skipped_examples.json').to_set

        re_ran_ar = @ar_ids - skipped
        expect(re_ran_ar).to(eq(@ar_ids),
                             'expected all AR-touching examples to re-run; ' \
                             "missing from re-run set: #{(@ar_ids - re_ran_ar).to_a.inspect}; " \
                             "skipped: #{skipped.to_a.inspect}")

        expect(skipped).to(include(@pure_id),
                           "pure-compute example #{@pure_id.inspect} should be skipped; " \
                           "got skipped: #{skipped.to_a.inspect}")
      ensure
        File.binwrite(schema_path, original)
      end
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/BeforeAfterAll, RSpec/InstanceVariable, RSpec/ExampleLength
