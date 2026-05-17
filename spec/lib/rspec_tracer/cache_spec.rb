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

  # Round-trip guard for 1.2.4: the example_id computation changed
  # (digest now reads example_group.description instead of .name and
  # excludes line numbers), but the on-disk cache JSON shape is
  # unchanged. A cache file written by v1.2.3 must still load cleanly
  # through the patched code — the new lookups simply miss against the
  # old example_ids (= one cold run on upgrade), but the load itself
  # must not raise.
  describe '#populate_from_disk (v1.2.4 round-trip guard)' do
    let(:tmp) { Dir.mktmpdir }
    let(:run_id) { 'pre124abc' }
    let(:run_dir) { File.join(tmp, run_id) }
    let(:legacy_example_id) { 'e3fdea47ac3a8995083ec0ba9784c95c' }

    after { FileUtils.remove_entry(tmp) if File.directory?(tmp) }

    before do
      Dir.mkdir(run_dir)
      File.write(File.join(tmp, 'last_run.json'), JSON.dump('run_id' => run_id), encoding: 'UTF-8')
      # Models a v1.2.3-written all_examples.json: example_group held
      # the OLD generated class name and the digest hashed it together
      # with line_number.
      File.write(
        File.join(run_dir, 'all_examples.json'),
        JSON.dump(
          legacy_example_id => {
            'example_group' => 'RSpec::ExampleGroups::Calculator::Add',
            'description' => 'adds 1 and 2 to 3',
            'full_description' => 'Calculator#add adds 1 and 2 to 3',
            'file_name' => '/spec/calculator_spec.rb',
            'line_number' => 14,
            'rerun_file_name' => '/spec/calculator_spec.rb',
            'rerun_line_number' => 14,
            'example_id' => legacy_example_id
          }
        ),
        encoding: 'UTF-8'
      )
    end

    it 'loads the cache via populate_from_disk without raising' do
      expect { cache.populate_from_disk(run_dir) }.not_to raise_error
    end

    it 'preserves the legacy example_id as the all_examples key (cache shape unchanged)' do
      cache.populate_from_disk(run_dir)

      expect(cache.all_examples).to have_key(legacy_example_id)
    end
  end
end
