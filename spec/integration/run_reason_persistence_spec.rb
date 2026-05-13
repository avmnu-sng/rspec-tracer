# frozen_string_literal: true

# End-to-end regression for #186 (and the field-test-2 widened scope):
# on warm runs, report.json#run_reason must surface the actual reason
# this run's filter classified the example with (Failed previously /
# Pending previously / Files changed / Environment changed / Interrupted
# previously), not the seeded prior-snapshot reason. The fix lives at
# RSpecTracer::Engine#register_example, which now overwrites the seeded
# entry in @all_examples instead of preserving it via `||=`.
#
# Drives the ruby_app fixture with a temp spec file containing a
# deliberately failing example. The around block guarantees the temp
# file is removed even when the test fails partway.

require 'bundler'
require 'fileutils'
require 'json'
require 'open3'

# rubocop:disable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength
RSpec.describe 'report.json#run_reason persistence on warm runs' do
  let(:fixture_root) { File.expand_path('../../benchmark/fixtures/ruby_app', __dir__) }
  let(:cache_dir)    { File.join(fixture_root, 'rspec_tracer_cache') }
  let(:report_dir)   { File.join(fixture_root, 'rspec_tracer_report') }
  let(:coverage_dir) { File.join(fixture_root, 'rspec_tracer_coverage') }
  let(:temp_spec)    { File.join(fixture_root, 'spec', 'run_reason_regression_spec.rb') }

  around do |example|
    Bundler.with_unbundled_env do
      FileUtils.rm_rf([cache_dir, report_dir, coverage_dir])
      example.run
    ensure
      FileUtils.rm_rf([cache_dir, report_dir, coverage_dir])
      FileUtils.rm_f(temp_spec)
    end
  end

  def run_rspec
    Open3.capture2e('bundle', 'exec', 'rspec', '--no-color', chdir: fixture_root)
  end

  def report_payload
    JSON.parse(File.read(File.join(report_dir, 'report.json'), encoding: 'UTF-8'))
  end

  def find_example(description_substring)
    report_payload['reports']['all_examples'].find do |e|
      e['description']&.include?(description_substring)
    end
  end

  def ensure_bundle_installed!
    Dir.chdir(fixture_root) do
      next if system('bundle check > /dev/null 2>&1')

      install_out, install_status = Open3.capture2e('bundle', 'install', '--quiet')
      raise "bundle install failed in #{fixture_root}:\n#{install_out}" unless install_status.success?
    end
  end

  before { ensure_bundle_installed! }

  it "tags 'Failed previously' on the warm re-run of a deliberately failing example" do
    File.write(temp_spec, <<~RUBY)
      RSpec.describe 'run_reason regression fixture' do
        it 'deliberately fails to exercise the failed_example reason path' do
          expect(true).to be(false)
        end
      end
    RUBY

    # Cold run: example is new — Filter classifies it as :no_cache.
    _, cold_status = run_rspec
    expect(cold_status.exitstatus).not_to eq(0), 'cold run should fail (deliberately)'
    cold_example = find_example('deliberately fails to exercise')
    expect(cold_example).not_to be_nil
    expect(cold_example['run_reason']).to eq('No cache')

    # Warm run: same spec file (digest unchanged); the failing example
    # is in failed_examples from the prev snapshot, so Filter classifies
    # it as :failed_example. Before the fix, the seeded "No cache" from
    # @all_examples leaked through unchanged.
    _, warm_status = run_rspec
    expect(warm_status.exitstatus).not_to eq(0), 'warm run should still fail (same example)'
    warm_example = find_example('deliberately fails to exercise')
    expect(warm_example).not_to be_nil
    expect(warm_example['run_reason']).to eq('Failed previously')
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength
