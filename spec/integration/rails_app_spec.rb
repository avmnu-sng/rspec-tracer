# frozen_string_literal: true

# M4.3 behavior-matrix integration test. Drives the reference Rails
# fixture at `spec/fixtures/rails_app/` via subprocess RSpec runs
# with rspec-tracer's v2 engine enabled, then mutates specific files
# and asserts which examples the filter re-runs on the next warm run.
#
# Each scenario re-runs the cold cache so residual mutations from
# prior scenarios can't leak digest state into the next one. The
# bundle + db setup runs once at suite start; subsequent colds just
# re-execute the fixture suite.
#
# Assertion philosophy
# --------------------
# Every scenario asserts on the set of example ids that re-ran (the
# diff of all_examples.json vs skipped_examples.json after the warm
# run). "Narrow" scenarios (template edit, new / deleted template)
# assert on the exact subset; "whole-suite" scenarios assert on the
# full count. A failure prints the expected/actual diff so CI logs
# stay actionable.

require 'bundler'
require 'fileutils'
require 'json'
require 'open3'
require 'set'

# Module-scoped shared state + helpers so rubocop's
# RSpec/LeakyConstantDeclaration stays quiet (constants live outside
# the describe block) and so the subprocess runner can be reused
# across the dozen scenarios without closure capture weirdness.
module RailsAppSpecHelpers
  FIXTURE_ROOT = File.expand_path('../fixtures/rails_app', __dir__)
  CACHE_DIR = File.join(FIXTURE_ROOT, 'rspec_tracer_cache')
  COVERAGE_DIR = File.join(FIXTURE_ROOT, 'rspec_tracer_coverage')
  REPORT_DIR = File.join(FIXTURE_ROOT, 'rspec_tracer_report')
  LOCAL_COVERAGE = File.join(FIXTURE_ROOT, 'coverage')
  TRACER_ENV = { 'RSPEC_TRACER' => '1' }.freeze
  SCRUB_DIRS = [CACHE_DIR, COVERAGE_DIR, REPORT_DIR, LOCAL_COVERAGE].freeze

  MUTATION_MARKER = "\n# rspec-tracer M4.3 behavior-matrix mutation marker\n"
  MUTATION_MARKER_VIEW = "\n<!-- rspec-tracer M4.3 behavior-matrix mutation marker -->\n"

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
    manifest = JSON.parse(File.read(File.join(CACHE_DIR, 'last_run.json'), encoding: 'UTF-8'))
    JSON.parse(File.read(File.join(CACHE_DIR, manifest.fetch('run_id'), name), encoding: 'UTF-8'))
  end
end

# The spec shells out to a subprocess per scenario and correlates
# cache state across runs; metric cops tuned for single-line
# expectations flatten the narrative that matters here.
# rubocop:disable RSpec/DescribeClass, RSpec/ExampleLength, RSpec/BeforeAfterAll, RSpec/InstanceVariable
RSpec.describe 'rails_app behavior matrix' do
  include RailsAppSpecHelpers

  before(:all) do
    RailsAppSpecHelpers.ensure_bundle_and_db
  end

  before do
    RailsAppSpecHelpers.clear_tracer_state
    out, status = RailsAppSpecHelpers.run_rspec_in_fixture
    raise "cold rspec failed (status=#{status.exitstatus}):\n#{out}" unless status.success?

    @cold_example_ids = RailsAppSpecHelpers.load_cache_file('all_examples.json').keys.to_set
    reverse_deps = RailsAppSpecHelpers.load_cache_file('reverse_dependency.json')
    @show_erb_renderers = reverse_deps.fetch('/app/views/users/show.html.erb', []).to_set
    raise 'expected show.html.erb to have cold renderers' if @show_erb_renderers.empty?
  end

  after(:all) do
    RailsAppSpecHelpers.clear_tracer_state
  end

  def all_example_ids
    @cold_example_ids
  end

  attr_reader :show_erb_renderers

  def warm_run(allow_failures: false)
    out, status = RailsAppSpecHelpers.run_rspec_in_fixture
    raise "warm rspec failed (status=#{status.exitstatus}):\n#{out}" unless status.success? || allow_failures

    skipped = RailsAppSpecHelpers.load_cache_file('skipped_examples.json').to_set
    re_run = all_example_ids - skipped
    { out: out, status: status, skipped: skipped, re_run: re_run }
  end

  def mutate(relative_path, marker: RailsAppSpecHelpers::MUTATION_MARKER)
    path = File.join(RailsAppSpecHelpers::FIXTURE_ROOT, relative_path)
    original = File.binread(path)
    File.open(path, 'ab') { |f| f.write(marker) }
    yield
  ensure
    File.binwrite(path, original) if original
  end

  def diff_message(expected:, actual:)
    missing = expected - actual
    extra = actual - expected
    [
      "expected #{expected.size} ids, got #{actual.size}",
      "missing (expected but not re-run): #{missing.to_a.sort.first(5).inspect}#{'...' if missing.size > 5}",
      "extra (re-ran but not expected): #{extra.to_a.sort.first(5).inspect}#{'...' if extra.size > 5}"
    ].join("\n")
  end

  describe 'scenario 1: no changes' do
    it 'skips every example on the warm run' do
      result = warm_run
      expect(result[:re_run]).to(be_empty, -> { diff_message(expected: Set.new, actual: result[:re_run]) })
    end
  end

  describe 'scenario 2: model mutation (app/models/user.rb)' do
    it 're-runs every example that transitively loaded the model (LoadedFilesTracker)' do
      mutate('app/models/user.rb') do
        result = warm_run
        # user.rb is pulled into every example's @loaded_set after the
        # first factory/query fires, so the M3.7 transitive-load path
        # attributes it broadly. Per-example narrowing waits for
        # M5.2's `tracks:` DSL.
        expect(result[:re_run].size).to be >= (all_example_ids.size * 0.9).to_i
      end
    end
  end

  describe 'scenario 3: template mutation (app/views/users/show.html.erb)' do
    it 're-runs only the examples that rendered it via ActionView notifications' do
      mutate('app/views/users/show.html.erb', marker: RailsAppSpecHelpers::MUTATION_MARKER_VIEW) do
        result = warm_run
        expect(result[:re_run]).to(eq(show_erb_renderers),
                                   -> { diff_message(expected: show_erb_renderers, actual: result[:re_run]) })
      end
    end
  end

  describe 'scenario 4: locale mutation (config/locales/en.yml)' do
    it 're-runs every example (coarse via declared-glob :locales)' do
      mutate('config/locales/en.yml') do
        result = warm_run
        expect(result[:re_run]).to(eq(all_example_ids),
                                   -> { diff_message(expected: all_example_ids, actual: result[:re_run]) })
      end
    end
  end

  describe 'scenario 5: schema mutation (db/schema.rb)' do
    it 're-runs every example that touched AR (every example under use_transactional_fixtures)' do
      mutate('db/schema.rb') do
        result = warm_run
        # use_transactional_fixtures wraps every example in an AR
        # transaction; the sql.active_record subscriber emits
        # schema.rb for every example on first query. Narrow AR
        # attribution only shows when some examples genuinely don't
        # touch the DB - this fixture has none.
        expect(result[:re_run]).to(eq(all_example_ids),
                                   -> { diff_message(expected: all_example_ids, actual: result[:re_run]) })
      end
    end
  end

  describe 'scenario 6: factory mutation (spec/factories/users.rb)' do
    it 're-runs every example (factories ride LoadedFilesTracker boot_set via factory_bot_rails)' do
      mutate('spec/factories/users.rb') do
        result = warm_run
        expect(result[:re_run]).to(eq(all_example_ids),
                                   -> { diff_message(expected: all_example_ids, actual: result[:re_run]) })
      end
    end
  end

  describe 'scenario 7: YAML fixture mutation (spec/fixtures/users.yml)' do
    it 're-runs every example (coarse via declared-glob :fixtures)' do
      mutate('spec/fixtures/users.yml') do
        result = warm_run
        expect(result[:re_run]).to(eq(all_example_ids),
                                   -> { diff_message(expected: all_example_ids, actual: result[:re_run]) })
      end
    end
  end

  describe 'scenario 8: Gemfile.lock mutation' do
    it 're-runs every example (whole-suite invalidator)' do
      mutate('Gemfile.lock') do
        result = warm_run
        expect(result[:re_run]).to(eq(all_example_ids),
                                   -> { diff_message(expected: all_example_ids, actual: result[:re_run]) })
      end
    end
  end

  describe 'scenario 9: .ruby-version mutation' do
    it 're-runs every example (whole-suite invalidator)' do
      mutate('.ruby-version') do
        result = warm_run
        expect(result[:re_run]).to(eq(all_example_ids),
                                   -> { diff_message(expected: all_example_ids, actual: result[:re_run]) })
      end
    end
  end

  describe 'scenario 10: .rspec-tracer config mutation' do
    it 're-runs every example (whole-suite invalidator)' do
      mutate('.rspec-tracer') do
        result = warm_run
        expect(result[:re_run]).to(eq(all_example_ids),
                                   -> { diff_message(expected: all_example_ids, actual: result[:re_run]) })
      end
    end
  end

  describe 'scenario 11: new template added' do
    it 'triggers zero re-runs (:views is not declared; NewFileDetector does not flag the add)' do
      new_template = File.join(RailsAppSpecHelpers::FIXTURE_ROOT, 'app/views/users/_m43_new.html.erb')
      begin
        File.write(new_template, "<span class=\"m43\">M4.3 new template</span>\n")
        result = warm_run
        expect(result[:re_run]).to(be_empty, -> { diff_message(expected: Set.new, actual: result[:re_run]) })
      ensure
        FileUtils.rm_f(new_template)
      end
    end
  end

  describe 'scenario 12: template deleted' do
    it 're-runs only the examples that had rendered the deleted template (expected to fail)' do
      target = File.join(RailsAppSpecHelpers::FIXTURE_ROOT, 'app/views/users/show.html.erb')
      backup = File.binread(target)
      begin
        File.delete(target)
        # Deleting a live template makes the renderers fail at the
        # Rails layer; `allow_failures: true` keeps the warm_run
        # helper from raising on a non-zero subprocess exit.
        result = warm_run(allow_failures: true)
        expect(result[:re_run]).to(eq(show_erb_renderers),
                                   -> { diff_message(expected: show_erb_renderers, actual: result[:re_run]) })
      ensure
        File.binwrite(target, backup)
      end
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/ExampleLength, RSpec/BeforeAfterAll, RSpec/InstanceVariable
