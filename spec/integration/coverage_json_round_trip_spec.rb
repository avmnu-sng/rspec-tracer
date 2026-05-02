# frozen_string_literal: true

# M8.0 byte-equivalence assertion: the post-retirement
# Reporters::CoverageJsonReporter must produce coverage.json that
# matches the pre-retirement legacy CoverageReporter / CoverageWriter
# output (byte-for-byte modulo the per-run timestamp + machine-local
# absolute path prefix). The committed golden was captured against
# the rails_app fixture before this branch's retirement commit; this
# spec drives the same fixture against the new emitter and structurally
# diffs.
#
# Path keys in coverage.json are ABSOLUTE; the round-trip relativizes
# both sides under the fixture root before comparison so the spec is
# machine-portable.

require 'bundler'
require 'json'
require 'open3'

require_relative '../support/fixture_bundle_helper'

# rubocop:disable RSpec/DescribeClass, RSpec/BeforeAfterAll, RSpec/MultipleExpectations, RSpec/ExampleLength
# rubocop:disable RSpec/InstanceVariable
RSpec.describe 'coverage.json byte-equivalence round-trip vs golden' do
  # Rails-major-specific golden: Rails 8.0 changes route loading to fire
  # AFTER Coverage.start (vs 7.x where it boots before), so config/routes.rb
  # enters the coverage map under 8.0 but not under 7.x. Same fixture, same
  # spec, different file boot order. Pick the golden that matches the
  # RAILS_VERSION env the matrix passes; fall back to the 7.x default.
  let(:golden_path) { File.join(FixtureBundleHelper::FIXTURE_ROOT, golden_filename) }
  let(:coverage_json_path) { File.join(FixtureBundleHelper::COVERAGE_DIR, 'coverage.json') }

  let(:golden_filename) do
    rails_version = ENV.fetch('RAILS_VERSION', '')
    rails_version.include?('8.') ? 'coverage_json.golden.rails8' : 'coverage_json.golden'
  end

  before(:all) do
    FixtureBundleHelper.ensure_bundle_and_db
  end

  before do
    FixtureBundleHelper.clear_tracer_state
    Bundler.with_unbundled_env do
      # CI is unset so Rails uses lazy-load in the fixture's test env
      # (config/environments/test.rb gates eager_load on ENV['CI']).
      # Eager-load runs during Rails boot - BEFORE rspec-tracer's
      # Coverage.start - so files loaded eagerly miss coverage and the
      # subprocess's coverage.json shrinks to whatever loads after
      # Coverage.start. The golden was captured in lazy-load mode (no
      # CI env); pin lazy-load here so byte-equivalence holds across
      # CI runners and local dev regardless of the outer ENV.
      env = {
        'RSPEC_TRACER' => '1',
        'RSPEC_TRACER_FIXTURE_NO_SIMPLECOV' => '1',
        'BUNDLE_FROZEN' => '1',
        'CI' => ''
      }
      @rspec_out, status = Open3.capture2e(env, 'bundle', 'exec', 'rspec', '--no-color',
                                           chdir: FixtureBundleHelper::FIXTURE_ROOT)
      raise "fixture rspec failed (status=#{status.exitstatus}):\n#{@rspec_out}" unless status.success?
    end
  end

  after(:all) do
    FixtureBundleHelper.clear_tracer_state
  end

  it 'emits a coverage.json with structural equality to the golden under fixture-root-relative keys' do
    expect(File).to exist(coverage_json_path)

    actual_payload = JSON.parse(File.read(coverage_json_path, encoding: 'UTF-8'))
    actual_relativized = relativize(actual_payload['RSpecTracer']['coverage'])

    if ENV['RSPEC_TRACER_M8_REGEN_GOLDEN'] == '1'
      File.write(
        golden_path,
        "#{JSON.pretty_generate(RSpecTracer: { coverage: actual_relativized, timestamp: 0 })}\n",
        encoding: 'UTF-8'
      )
      warn "[M8.0 golden capture] wrote #{actual_relativized.size} keys -> #{golden_path}"
      next
    end

    golden_payload = JSON.parse(File.read(golden_path, encoding: 'UTF-8'))

    expect(actual_payload['RSpecTracer']['timestamp']).to be_a(Integer)
    expect(actual_relativized).not_to be_empty
    if actual_relativized != golden_payload['RSpecTracer']['coverage']
      warn "[M8.0 round-trip diff debug] inner rspec output:\n#{@rspec_out}"
    end
    expect(actual_relativized).to eq(golden_payload['RSpecTracer']['coverage'])
  end

  def relativize(coverage_hash)
    prefix = "#{FixtureBundleHelper::FIXTURE_ROOT}/"
    coverage_hash.each_with_object({}) do |(path, lines), acc|
      key = path.start_with?(prefix) ? path[prefix.length..] : path
      acc[key] = lines
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/BeforeAfterAll, RSpec/MultipleExpectations, RSpec/ExampleLength
# rubocop:enable RSpec/InstanceVariable
