# frozen_string_literal: true

require 'spec_helper'

# Loads the benchmark harness module without auto-running
# (`if $PROGRAM_NAME == __FILE__` guard at the bottom of harness.rb
# keeps `BenchmarkHarness.main` from firing on require).
require_relative '../../benchmark/harness'

# Verifies that `INFORMATIONAL_SCENARIOS` correctly removes
# wall-clock gating for variance-prone parallel-worker scenarios
# while leaving other scenarios under the canonical
# REGRESSION_FAIL_RATIO / REGRESSION_WARN_RATIO gates.
#
# rubocop:disable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength
RSpec.describe 'BenchmarkHarness.compare_to_ratchet' do
  let(:harness) do
    Module.new do
      extend BenchmarkHarness

      module_function

      def compare(results, ratchet)
        compare_to_ratchet(results, ratchet)
      end
    end
  end

  let(:ratchet) do
    {
      'scenarios' => {
        'cold_ruby' => { 'p50' => 0.40 },
        'parallel_tests_2_workers' => { 'p50' => 0.866 }
      }
    }
  end

  context 'when scenario is in INFORMATIONAL_SCENARIOS' do
    it 'returns :informational status regardless of ratio magnitude' do
      results = [
        { 'scenario' => 'parallel_tests_2_workers', 'p50' => 1.976 } # 2.28x baseline
      ]
      statuses = harness.compare(results, ratchet)

      expect(statuses['parallel_tests_2_workers'][:status]).to eq(:informational)
      expect(statuses['parallel_tests_2_workers'][:ratio]).to be_within(0.01).of(2.28)
    end

    it 'returns :informational even when ratio is well below WARN threshold' do
      results = [
        { 'scenario' => 'parallel_tests_2_workers', 'p50' => 0.50 } # 0.58x baseline (would be OK normally)
      ]
      statuses = harness.compare(results, ratchet)

      expect(statuses['parallel_tests_2_workers'][:status]).to eq(:informational)
    end
  end

  context 'when scenario is not informational' do
    it 'returns :fail when ratio exceeds REGRESSION_FAIL_RATIO' do
      results = [{ 'scenario' => 'cold_ruby', 'p50' => 0.55 }] # 1.375x of 0.40 baseline > 1.30
      statuses = harness.compare(results, ratchet)

      expect(statuses['cold_ruby'][:status]).to eq(:fail)
    end

    it 'returns :warn when ratio is between WARN and FAIL' do
      results = [{ 'scenario' => 'cold_ruby', 'p50' => 0.48 }] # 1.20x of 0.40 baseline
      statuses = harness.compare(results, ratchet)

      expect(statuses['cold_ruby'][:status]).to eq(:warn)
    end

    it 'returns :ok when ratio is below WARN threshold' do
      results = [{ 'scenario' => 'cold_ruby', 'p50' => 0.42 }] # 1.05x of 0.40 baseline
      statuses = harness.compare(results, ratchet)

      expect(statuses['cold_ruby'][:status]).to eq(:ok)
    end
  end

  it 'INFORMATIONAL_SCENARIOS contains parallel_tests_2_workers' do
    expect(BenchmarkHarness::INFORMATIONAL_SCENARIOS).to include('parallel_tests_2_workers')
  end

  describe 'gate enforcement (any_fail filter)' do
    it 'an :informational status with high ratio does NOT trigger any_fail' do
      results = [
        { 'scenario' => 'cold_ruby', 'p50' => 0.41 }, # OK
        { 'scenario' => 'parallel_tests_2_workers', 'p50' => 5.0 } # 5.77x INFO
      ]
      statuses = harness.compare(results, ratchet)
      any_fail = statuses.values.any? { |s| s.is_a?(Hash) && s[:status] == :fail }

      expect(any_fail).to be(false)
    end

    it 'a :fail status on a gated scenario DOES trigger any_fail' do
      results = [{ 'scenario' => 'cold_ruby', 'p50' => 0.55 }] # 1.375x FAIL
      statuses = harness.compare(results, ratchet)
      any_fail = statuses.values.any? { |s| s.is_a?(Hash) && s[:status] == :fail }

      expect(any_fail).to be(true)
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleExpectations, RSpec/ExampleLength
