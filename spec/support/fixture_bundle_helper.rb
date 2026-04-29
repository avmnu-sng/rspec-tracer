# frozen_string_literal: true

require 'bundler'
require 'fileutils'
require 'json'

# Shared fixture-bundle helper for the rails_app integration specs.
# Both rails_app_spec.rb and narrow_ar_schema_spec.rb drive the same
# spec/fixtures/rails_app/ subprocess pattern; the bundle ladder +
# tracer-state scrub + cache reader are byte-identical between the
# two files prior to extraction.
#
# Per-spec helper modules (RailsAppSpecHelpers /
# NarrowArSchemaSpecHelpers) keep their own TRACER_ENV +
# run_rspec_in_fixture variants since the env vars and target spec
# file differ.
#
# `def self.x` (over module_function) per
# feedback_mutation_friendly_modules: keeps the methods discoverable
# under mutant should this helper ever be in scope; currently it
# isn't (test-support code), but the convention is consistent.
module FixtureBundleHelper
  FIXTURE_ROOT = File.expand_path('../fixtures/rails_app', __dir__)
  CACHE_DIR = File.join(FIXTURE_ROOT, 'rspec_tracer_cache')
  COVERAGE_DIR = File.join(FIXTURE_ROOT, 'rspec_tracer_coverage')
  REPORT_DIR = File.join(FIXTURE_ROOT, 'rspec_tracer_report')
  LOCAL_COVERAGE = File.join(FIXTURE_ROOT, 'coverage')
  SCRUB_DIRS = [CACHE_DIR, COVERAGE_DIR, REPORT_DIR, LOCAL_COVERAGE].freeze

  def self.ensure_bundle_and_db
    Bundler.with_unbundled_env do
      Dir.chdir(FIXTURE_ROOT) do
        gemfile_env = { 'BUNDLE_GEMFILE' => File.join(FIXTURE_ROOT, 'Gemfile') }
        unless system(gemfile_env, 'bundle', 'check', out: File::NULL, err: File::NULL)
          # Cross-interpreter invocations (MRI <-> JRuby on the same
          # gitignored fixture lockfile) leave a platform-mismatched
          # lock that `bundle install` can't always reconcile in one
          # pass when the Rails-line default shifts in the same step.
          # Wipe the lock so Bundler resolves fresh against the
          # current interpreter. Same-interpreter repeats keep
          # `bundle check` green, so this rm only fires on the
          # exception path. Per M8.1-B's cross-interpreter resilience
          # work + feedback_cross_interpreter_fixture_helper.
          FileUtils.rm_f(File.join(FIXTURE_ROOT, 'Gemfile.lock'))
          system(gemfile_env, 'bundle', 'install', '--quiet') || raise('bundle install failed')
        end

        system('bundle', 'exec', 'rails', 'db:test:prepare',
               out: File::NULL, err: File::NULL) || raise('db:test:prepare failed')
      end
    end
  end

  def self.clear_tracer_state
    FileUtils.rm_rf(SCRUB_DIRS)
  end

  def self.load_cache_file(name)
    manifest = JSON.parse(File.read(File.join(CACHE_DIR, 'last_run.json'), encoding: 'UTF-8'))
    JSON.parse(File.read(File.join(CACHE_DIR, manifest.fetch('run_id'), name), encoding: 'UTF-8'))
  end
end
