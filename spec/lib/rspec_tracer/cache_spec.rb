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

    # Regression guard: cache JSON files contain UTF-8 bytes whenever a
    # spec description uses a non-ASCII character (e.g. the KNOWN_ISSUES
    # "§B5" reference). Without an explicit `encoding: 'UTF-8'` on the
    # File.read, a shell with `LANG=` unset makes Ruby default to
    # US-ASCII and the read raises Encoding::InvalidByteSequenceError on
    # the first xC2 byte, taking spec_helper down before any example runs.
    context 'when the cache JSON contains UTF-8 bytes under a US-ASCII default external' do
      let(:run_id) { 'utf8abc' }
      let(:utf8_key) { "example with \u00A7" }

      around do |example|
        original_external = Encoding.default_external
        original_verbose = $VERBOSE
        $VERBOSE = nil
        Encoding.default_external = Encoding::US_ASCII
        example.run
      ensure
        Encoding.default_external = original_external
        $VERBOSE = original_verbose
      end

      before do
        File.write(File.join(tmp, 'last_run.json'), JSON.dump('run_id' => run_id), encoding: 'UTF-8')
        run_dir = File.join(tmp, run_id)
        Dir.mkdir(run_dir)
        File.write(
          File.join(run_dir, 'examples_coverage.json'),
          JSON.dump(utf8_key => { '/lib/foo.rb' => [1, 0, 1] }),
          encoding: 'UTF-8'
        )
        allow(RSpecTracer).to receive_messages(cache_path: tmp, parallel_tests?: false)
      end

      it 'reads the cache without raising Encoding::InvalidByteSequenceError' do
        expect { cache.cached_examples_coverage }.not_to raise_error
      end

      it 'preserves UTF-8 keys through the JSON round-trip' do
        expect(cache.cached_examples_coverage).to have_key(utf8_key)
      end
    end
  end
end
