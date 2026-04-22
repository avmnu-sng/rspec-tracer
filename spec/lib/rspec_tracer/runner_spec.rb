# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# Legacy Runner is no longer auto-loaded post-M5.1 (the RSpec hook
# rework retired the use_v2_tracker bridge and stopped requiring
# runner.rb from the top-level entry). Load it explicitly for this
# unit-test module; the class stays in-tree until Phase 6 retires
# the reporter stack.
require 'rspec_tracer/runner'

RSpec.describe RSpecTracer::Runner do
  subject(:runner) { described_class.new }

  let(:tmp) { Dir.mktmpdir }

  after { FileUtils.remove_entry(tmp) if File.directory?(tmp) }

  before do
    allow(RSpecTracer).to receive_messages(
      cache_path: tmp,
      parallel_tests?: false,
      run_all_examples: false,
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

  describe '#register_file_dependency (private)' do
    let(:example_id) { 'ex_1' }

    before do
      allow(runner.reporter).to receive_messages(
        example_interrupted?: false,
        duplicate_example?: false
      )
    end

    context 'when SourceFile.from_path returns nil (gem-generated example)' do
      before do
        allow(RSpecTracer::SourceFile).to receive(:from_path).and_return(nil)
        allow(runner.reporter).to receive(:register_source_file)
        allow(runner.reporter).to receive(:register_dependency)
      end

      it 'returns false and registers neither source file nor dependency (regression for B3)',
         :aggregate_failures do
        result = runner.send(:register_file_dependency, example_id, '/nonexistent/file.rb')

        expect(result).to be(false)
        expect(runner.reporter).not_to have_received(:register_source_file)
        expect(runner.reporter).not_to have_received(:register_dependency)
      end
    end
  end

  describe '#register_example_file_dependency (private)' do
    let(:example_id) { 'ex_1' }

    before do
      allow(runner.reporter).to receive_messages(
        example_interrupted?: false,
        duplicate_example?: false
      )
    end

    context 'when SourceFile.from_name returns nil' do
      before do
        allow(RSpecTracer::SourceFile).to receive(:from_name).and_return(nil)
        allow(runner.reporter).to receive(:register_source_file)
        allow(runner.reporter).to receive(:register_dependency)
      end

      it 'returns early and registers neither source file nor dependency (regression for B3)',
         :aggregate_failures do
        expect do
          runner.send(:register_example_file_dependency, example_id, '/nonexistent.rb')
        end.not_to raise_error

        expect(runner.reporter).not_to have_received(:register_source_file)
        expect(runner.reporter).not_to have_received(:register_dependency)
      end
    end
  end
end
