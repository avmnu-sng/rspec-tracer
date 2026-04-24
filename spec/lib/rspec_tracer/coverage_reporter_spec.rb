# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RSpecTracer::CoverageReporter do
  describe '#merge_coverage with nil line-coverage entries' do
    subject(:reporter) { described_class.allocate }

    let(:file_path) { '/tmp/some_file.rb' }
    let(:missed_coverage) { { file_path => { '0' => 2, '2' => 3 } } }
    let(:initial_coverage) { [nil, 1, nil] }

    before do
      reporter.instance_variable_set(:@mode, RSpecTracer::CoverageReporter::COVERAGE_MODE[:array])
      reporter.instance_variable_set(:@coverage, { file_path => initial_coverage })

      stub = { file_path => initial_coverage }
      reporter.define_singleton_method(:peek_coverage) { stub }
    end

    it 'does not crash on nil + strength (regression for B4)' do
      expect { reporter.merge_coverage(missed_coverage) }.not_to raise_error
    end

    it 'treats nil as 0 when summing coverage (regression for B4)', :aggregate_failures do
      reporter.merge_coverage(missed_coverage)
      result = reporter.coverage[file_path]
      expect(result[0]).to eq(2)
      expect(result[2]).to eq(3)
    end
  end
end
