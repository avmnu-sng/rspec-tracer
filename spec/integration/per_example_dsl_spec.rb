# frozen_string_literal: true

# End-to-end integration for the per-example `tracks:` DSL.
# Drives the reference Rails fixture at `spec/fixtures/rails_app/`
# via subprocess RSpec. The fixture's feature_flags_spec declares
# `tracks: { env: 'RAILS_APP_FORCE_REVIEW' }` on the
# `.require_review?` describe block (an ENV-branch blind spot that
# Coverage / IO observation cannot see).
#
# Assertion philosophy matches rails_app_spec.rb's behavior-matrix pattern:
# assert on the set of examples that re-ran on warm (all_examples
# minus skipped_examples), not just exit status. An env mutation
# between cold and warm must re-run exactly the three
# ENV-branch examples and skip every other example.

require 'bundler'
require 'fileutils'
require 'json'
require 'open3'
require 'set'

module PerExampleDslSpecHelpers
  FIXTURE_ROOT = File.expand_path('../fixtures/rails_app', __dir__)
  CACHE_DIR = File.join(FIXTURE_ROOT, 'rspec_tracer_cache')
  COVERAGE_DIR = File.join(FIXTURE_ROOT, 'rspec_tracer_coverage')
  REPORT_DIR = File.join(FIXTURE_ROOT, 'rspec_tracer_report')
  LOCAL_COVERAGE = File.join(FIXTURE_ROOT, 'coverage')
  TRACER_ENV = { 'RSPEC_TRACER' => '1' }.freeze
  SCRUB_DIRS = [CACHE_DIR, COVERAGE_DIR, REPORT_DIR, LOCAL_COVERAGE].freeze

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

  # Ids of examples that actually re-ran on warm = all_examples - skipped_examples.
  # The v2 seed_state_from_previous path carries prior skipped ids into
  # all_examples, so this diff is the exact re-run set.
  def re_run_example_ids_after_warm
    all_examples = load_cache_file('all_examples.json')
    skipped = load_cache_file('skipped_examples.json')
    (all_examples.keys - skipped.to_a).to_set
  end

  # The feature_flags env-branch describe has three examples
  # (unset / '1' / '0' branches of RAILS_APP_FORCE_REVIEW).
  def env_branch_example_descriptions
    [
      'reflects the features.json default when ENV is unset',
      'is true when RAILS_APP_FORCE_REVIEW=1',
      'is false for any other ENV value'
    ]
  end

  # Wildcard exercise: the same fixture spec also has a separate
  # describe with `tracks: { env: 'RAILS_APP_*' }`. Its two examples
  # depend on RAILS_APP_FORCE_REVIEW via the wildcard expansion path,
  # not the literal name path.
  def wildcard_branch_example_descriptions
    [
      'matches RAILS_APP_FORCE_REVIEW via the RAILS_APP_* wildcard',
      'pulls the un-set default through the wildcard match'
    ]
  end

  # Filter the all_examples map down to the env-branch describe's
  # examples by full_description prefix match.
  # `full` is a String; include? is a substring check here, not array
  # membership, so intersect? doesn't apply.
  # rubocop:disable Style/ArrayIntersect
  def env_branch_ids(all_examples)
    all_examples.select do |_, meta|
      full = meta['full_description'] || meta[:full_description]
      env_branch_example_descriptions.any? { |d| full.to_s.include?(d) }
    end.keys.to_set
  end

  def wildcard_branch_ids(all_examples)
    all_examples.select do |_, meta|
      full = meta['full_description'] || meta[:full_description]
      wildcard_branch_example_descriptions.any? { |d| full.to_s.include?(d) }
    end.keys.to_set
  end
  # rubocop:enable Style/ArrayIntersect
end

# rubocop:disable RSpec/DescribeClass, RSpec/BeforeAfterAll, RSpec/InstanceVariable
# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe 'per-example tracks DSL integration' do
  include PerExampleDslSpecHelpers

  before(:all) do
    PerExampleDslSpecHelpers.ensure_bundle_and_db
    PerExampleDslSpecHelpers.clear_tracer_state

    # Cold run with RAILS_APP_FORCE_REVIEW unset. Registers every
    # example in the cache, including the env-branch describe's
    # three examples (which declare tracks: { env: '...' }).
    @cold_out, @cold_status = PerExampleDslSpecHelpers.run_rspec_in_fixture
    raise "cold run failed:\n#{@cold_out}" unless @cold_status.success?

    @cold_all_examples = PerExampleDslSpecHelpers.load_cache_file('all_examples.json')
    @cold_env_snapshot = PerExampleDslSpecHelpers.load_cache_file('env_snapshot.json')
    @expected_env_branch_ids = PerExampleDslSpecHelpers.env_branch_ids(@cold_all_examples)

    # Warm run with RAILS_APP_FORCE_REVIEW flipped. Only the three
    # env-branch examples should re-run; everything else is skipped.
    @warm_out, @warm_status = PerExampleDslSpecHelpers.run_rspec_in_fixture(
      'RAILS_APP_FORCE_REVIEW' => '1'
    )
    raise "warm run failed:\n#{@warm_out}" unless @warm_status.success?

    @re_run_ids = PerExampleDslSpecHelpers.re_run_example_ids_after_warm
    @warm_env_snapshot = PerExampleDslSpecHelpers.load_cache_file('env_snapshot.json')
  end

  after(:all) { PerExampleDslSpecHelpers.clear_tracer_state }

  describe 'cold run persists env_snapshot for the declared key' do
    it 'records RAILS_APP_FORCE_REVIEW in env_snapshot.json' do
      expect(@cold_env_snapshot).to have_key('RAILS_APP_FORCE_REVIEW')
    end

    it 'does not record env keys no example tracked' do
      expect(@cold_env_snapshot.keys).to eq(['RAILS_APP_FORCE_REVIEW'])
    end
  end

  describe 'warm run with the tracked env flipped' do
    it 'captured the cold-run baseline (sanity)' do
      expect(@expected_env_branch_ids.size).to eq(3),
                                               "expected 3 env-branch examples, got #{@expected_env_branch_ids.size}"
    end

    # The re-run set is the union of the literal-tracks describe
    # (3 examples) + the wildcard-tracks describe (2 examples). Both
    # depend on RAILS_APP_FORCE_REVIEW; the wildcard `RAILS_APP_*`
    # expands to the same concrete env name at register_tracks time.
    it 're-runs exactly the literal + wildcard env-branch examples, skipping everything else' do
      wildcard_ids = PerExampleDslSpecHelpers.wildcard_branch_ids(@cold_all_examples)
      expected = @expected_env_branch_ids + wildcard_ids

      expect(expected.size).to eq(5),
                               "expected 3 literal + 2 wildcard env-branch examples, got #{expected.size}"

      unexpected_reruns = @re_run_ids - expected
      missed_reruns = expected - @re_run_ids
      diff_msg = "unexpected reruns: #{unexpected_reruns.to_a} / missed: #{missed_reruns.to_a}"

      expect([unexpected_reruns, missed_reruns]).to eq([Set.new, Set.new]), diff_msg
    end

    it 'updates env_snapshot to the new digest' do
      expect(@warm_env_snapshot['RAILS_APP_FORCE_REVIEW']).not_to eq(@cold_env_snapshot['RAILS_APP_FORCE_REVIEW'])
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/BeforeAfterAll, RSpec/InstanceVariable
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
