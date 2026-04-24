# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe RSpecTracer::Runner do
  subject(:runner) { described_class.new }

  let(:tmp) { Dir.mktmpdir }

  after { FileUtils.remove_entry(tmp) if File.directory?(tmp) }

  before do
    allow(RSpecTracer).to receive_messages(
      cache_path: tmp,
      parallel_tests?: false,
      filters: []
    )
  end

  describe '#generate_missed_coverage' do
    context 'when cached_examples_coverage returns nil' do
      before do
        allow(runner.cache).to receive(:cached_examples_coverage).and_return(nil)
      end

      it 'returns an empty missed-coverage map (regression for B2)' do
        expect(runner.generate_missed_coverage).to eq({})
      end
    end

    context 'when a strength value is nil' do
      let(:example_id) { 'example_xyz' }
      let(:file_path) { '/tmp/some_file.rb' }

      before do
        allow(runner.cache).to receive(:cached_examples_coverage).and_return(
          example_id => { file_path => { '0' => nil, '1' => 3 } }
        )
        allow(runner.reporter).to receive_messages(
          example_interrupted?: false,
          duplicate_example?: false,
          example_skipped?: true,
          file_deleted?: false
        )
      end

      it 'treats nil strength as 0 when summing coverage (regression for B2)', :aggregate_failures do
        missed = runner.generate_missed_coverage

        expect(missed).to have_key(file_path)
        expect(missed[file_path]['0']).to eq(0)
        expect(missed[file_path]['1']).to eq(3)
      end
    end
  end
end
