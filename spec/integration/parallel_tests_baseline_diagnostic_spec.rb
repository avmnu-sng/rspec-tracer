# frozen_string_literal: true

# H7 diagnostic (PR #100 CI flake investigation).
#
# Runs the exact same parallel_rspec harness as
# `parallel_tests_spec.rb` but against a sibling fixture that has NO
# rspec-tracer in its Gemfile or spec_helper. If the hang ever
# observed on GHA ruby-parallel cells reproduces here, the flake is
# upstream (parallel_tests + GHA-environmental) and outside our
# code's causal chain. If it does NOT reproduce, rspec-tracer is
# implicated and the next step is H3/H5 from the session notes.
#
# This spec is intentionally short-lived: to be reverted together
# with the sibling fixture once H7 is answered.

require 'bundler'
require 'open3'

module ParallelTestsBaselineDiagnosticHelpers
  FIXTURE_ROOT = File.expand_path(
    '../../benchmark/fixtures/ruby_app_no_tracer', __dir__
  )

  module_function

  def ensure_bundle!
    Bundler.with_unbundled_env do
      Dir.chdir(FIXTURE_ROOT) do
        unless system('bundle', 'check', out: File::NULL, err: File::NULL)
          out, status = Open3.capture2e('bundle', 'install', '--quiet')
          raise "bundle install failed in #{FIXTURE_ROOT}:\n#{out}" unless status.success?
        end
      end
    end
  end

  def run_parallel
    Bundler.with_unbundled_env do
      Open3.capture2e({ 'PARALLEL_TEST_GROUPS' => '2' },
                      'bundle', 'exec', 'parallel_rspec', 'spec',
                      chdir: FIXTURE_ROOT)
    end
  end
end

# rubocop:disable RSpec/DescribeClass, RSpec/BeforeAfterAll, RSpec/InstanceVariable
RSpec.describe 'parallel_tests baseline (no rspec-tracer) diagnostic' do
  include ParallelTestsBaselineDiagnosticHelpers

  before(:all) do
    ParallelTestsBaselineDiagnosticHelpers.ensure_bundle!

    @first_out, @first_status = ParallelTestsBaselineDiagnosticHelpers.run_parallel
    @second_out, @second_status = ParallelTestsBaselineDiagnosticHelpers.run_parallel
  end

  it 'first parallel_rspec run exits 0' do
    expect(@first_status.exitstatus).to eq(0), "first run output:\n#{@first_out}"
  end

  it 'second parallel_rspec run exits 0' do
    expect(@second_status.exitstatus).to eq(0), "second run output:\n#{@second_out}"
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/BeforeAfterAll, RSpec/InstanceVariable
