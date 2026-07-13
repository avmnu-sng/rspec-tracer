# frozen_string_literal: true

# End-to-end regression for #194: flaky-test detection silently
# regressed in 2.0.0.pre.1: registry exposes :flaky status, the
# filter recognizes :flaky_example, and the JSON / HTML reporters
# emit flaky_examples, but no production code path transitions an
# example into the :flaky bucket. README pitches rspec-tracer as a
# "flaky-test detector" in its first paragraph; 1.x had detection
# since v1.0.0; the rewrite lost the transition logic.
#
# This spec drives the ruby_app fixture with a temp spec whose
# pass/fail outcome flips on a FAIL env var, then walks the
# canonical detection cycle and the sticky semantic:
#
#   Run 1 (FAIL=1)   -> fails. Stored as :failed.
#   Run 2 (FAIL nil) -> passes. Transitions to :flaky.
#   Run 3 (FAIL nil) -> passes. Sticky: stays :flaky.
#   Run 4 (FAIL=1)   -> fails. Sticky: stays :flaky (NOT :failed).
#
# Mirrors 1.x's ReportGenerator#generate_flaky_examples_report
# contract under 2.0's single-status-per-example registry: a
# previously-flaky example stays flaky regardless of this run's
# outcome, and a previously-failed-now-passed example transitions.

require 'bundler'
require 'fileutils'
require 'json'
require 'open3'

# rubocop:disable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength
RSpec.describe 'flaky-test detection across runs (issue #194)' do
  let(:fixture_root) { File.expand_path('../../benchmark/fixtures/ruby_app', __dir__) }
  let(:cache_dir)    { File.join(fixture_root, 'rspec_tracer_cache') }
  let(:report_dir)   { File.join(fixture_root, 'rspec_tracer_report') }
  let(:coverage_dir) { File.join(fixture_root, 'rspec_tracer_coverage') }
  let(:temp_spec)    { File.join(fixture_root, 'spec', 'flaky_detection_fixture_spec.rb') }

  around do |example|
    Bundler.with_unbundled_env do
      FileUtils.rm_rf([cache_dir, report_dir, coverage_dir])
      example.run
    ensure
      FileUtils.rm_rf([cache_dir, report_dir, coverage_dir])
      FileUtils.rm_f(temp_spec)
    end
  end

  # FAIL is explicitly threaded so the parent test runner's env can't
  # leak in. `'FAIL' => nil` deletes the var entirely from the child.
  def run_rspec(fail_env: nil)
    Open3.capture2e({ 'FAIL' => fail_env }, 'bundle', 'exec', 'rspec', '--no-color', chdir: fixture_root)
  end

  def ensure_bundle_installed!
    Dir.chdir(fixture_root) do
      next if system('bundle check > /dev/null 2>&1')

      install_out, install_status = Open3.capture2e('bundle', 'install', '--quiet')
      raise "bundle install failed in #{fixture_root}:\n#{install_out}" unless install_status.success?
    end
  end

  before { ensure_bundle_installed! }

  def report_payload
    JSON.parse(File.read(File.join(report_dir, 'report.json'), encoding: 'UTF-8'))
  end

  def find_example(description_substring)
    report_payload['reports']['all_examples'].find do |e|
      e['description']&.include?(description_substring)
    end
  end

  def flaky_ids
    report_payload['reports']['flaky_examples'].map { |e| e['id'] }
  end

  def write_flaky_fixture
    File.write(temp_spec, <<~RUBY)
      RSpec.describe 'flaky detection fixture' do
        it 'pass-or-fail based on FAIL env var' do
          expect(ENV['FAIL']).to be_nil
        end
      end
    RUBY
  end

  it 'detects failed -> passed transition and keeps flaky sticky across subsequent runs' do
    write_flaky_fixture

    _, status1 = run_rspec(fail_env: '1')
    expect(status1.exitstatus).not_to eq(0), 'run 1 should fail (FAIL=1)'
    fixture_id = find_example('pass-or-fail')&.fetch('id')
    expect(fixture_id).not_to be_nil
    expect(flaky_ids).not_to include(fixture_id), 'no flaky transition yet on first run'

    _, status2 = run_rspec
    expect(status2.exitstatus).to eq(0), 'run 2 should pass (FAIL unset)'
    expect(flaky_ids).to include(fixture_id), 'failed -> passed promotes to :flaky'

    _, status3 = run_rspec
    expect(status3.exitstatus).to eq(0), 'run 3 should pass (FAIL unset)'
    expect(flaky_ids).to include(fixture_id), 'sticky: prev-flaky + this-run-passed stays :flaky'
  end

  it 'keeps a previously-flaky example sticky when it fails again' do
    write_flaky_fixture

    _, status1 = run_rspec(fail_env: '1')
    expect(status1.exitstatus).not_to eq(0)
    fixture_id = find_example('pass-or-fail')&.fetch('id')
    expect(fixture_id).not_to be_nil

    _, status2 = run_rspec
    expect(status2.exitstatus).to eq(0)
    expect(flaky_ids).to include(fixture_id), 'failed -> passed promotes to :flaky'

    _, status3 = run_rspec(fail_env: '1')
    expect(status3.exitstatus).not_to eq(0), 'run 3 should fail (FAIL=1 reintroduced)'
    expect(flaky_ids).to include(fixture_id), 'sticky: prev-flaky + this-run-failed stays :flaky'
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength
