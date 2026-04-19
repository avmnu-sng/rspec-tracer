# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe RSpecTracer::Cache do
  subject(:cache) { described_class.new }

  describe '#cached_examples_coverage' do
    let(:tmp) { Dir.mktmpdir }

    after { FileUtils.remove_entry(tmp) if File.directory?(tmp) }

    context 'when last_run.json does not exist' do
      before do
        allow(RSpecTracer).to receive_messages(cache_path: tmp, parallel_tests?: false)
      end

      it 'returns an empty hash' do
        expect(cache.cached_examples_coverage).to eq({})
      end

      it 'memoizes the result across calls' do
        first = cache.cached_examples_coverage
        second = cache.cached_examples_coverage
        expect(first).to equal(second)
      end
    end

    context 'when last_run.json exists but examples_coverage.json is missing' do
      let(:run_id) { 'abc123' }

      before do
        File.write(File.join(tmp, 'last_run.json'), JSON.dump('run_id' => run_id))
        Dir.mkdir(File.join(tmp, run_id))
        allow(RSpecTracer).to receive_messages(cache_path: tmp, parallel_tests?: false)
      end

      it 'returns an empty hash, never nil (regression for B1)' do
        expect(cache.cached_examples_coverage).to eq({})
      end

      it 'memoizes on second call (regression for B1)' do
        cache.cached_examples_coverage
        expect(cache.instance_variable_get(:@examples_coverage)).not_to be_nil
      end
    end
  end
end
