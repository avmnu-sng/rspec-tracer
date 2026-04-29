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
RSpec.describe 'coverage.json byte-equivalence round-trip vs golden' do
  let(:golden_path) { File.join(FixtureBundleHelper::FIXTURE_ROOT, 'coverage_json.golden') }
  let(:coverage_json_path) { File.join(FixtureBundleHelper::COVERAGE_DIR, 'coverage.json') }

  before(:all) do
    FixtureBundleHelper.ensure_bundle_and_db
  end

  before do
    FixtureBundleHelper.clear_tracer_state
    Bundler.with_unbundled_env do
      env = {
        'RSPEC_TRACER' => '1',
        'RSPEC_TRACER_FIXTURE_NO_SIMPLECOV' => '1',
        'BUNDLE_FROZEN' => '1'
      }
      out, status = Open3.capture2e(env, 'bundle', 'exec', 'rspec', '--no-color',
                                    chdir: FixtureBundleHelper::FIXTURE_ROOT)
      raise "fixture rspec failed (status=#{status.exitstatus}):\n#{out}" unless status.success?
    end
  end

  after(:all) do
    FixtureBundleHelper.clear_tracer_state
  end

  it 'emits a coverage.json with structural equality to the golden under fixture-root-relative keys' do
    expect(File).to exist(coverage_json_path)

    actual_payload = JSON.parse(File.read(coverage_json_path, encoding: 'UTF-8'))
    golden_payload = JSON.parse(File.read(golden_path, encoding: 'UTF-8'))

    expect(actual_payload['RSpecTracer']['timestamp']).to be_a(Integer)
    expect(actual_payload.dig('RSpecTracer', 'coverage')).not_to be_empty
    expect(relativize(actual_payload['RSpecTracer']['coverage']))
      .to eq(golden_payload['RSpecTracer']['coverage'])
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
