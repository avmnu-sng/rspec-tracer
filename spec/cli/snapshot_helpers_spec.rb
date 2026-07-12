# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'set'

require 'rspec_tracer/cli/snapshot_helpers'
require 'rspec_tracer/storage/json_backend'
require 'rspec_tracer/storage/snapshot'
require 'rspec_tracer/storage/schema'

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe RSpecTracer::CLI::SnapshotHelpers do
  let(:stderr) { StringIO.new }

  describe '.help_requested?' do
    it 'is true for empty args' do
      expect(described_class.help_requested?([])).to be(true)
    end

    it 'is true when -h or --help appears anywhere' do
      expect(described_class.help_requested?(%w[foo -h])).to be(true)
      expect(described_class.help_requested?(%w[--help foo])).to be(true)
    end

    it 'is false for ordinary positional args' do
      expect(described_class.help_requested?(%w[lib/foo.rb])).to be(false)
    end
  end

  describe '.load_snapshot' do
    it 'prints a prefixed no-cache message and returns nil when no run is recorded' do
      Dir.mktmpdir do |dir|
        allow(RSpecTracer).to receive(:storage_backend).and_return(:json)
        expect(described_class.load_snapshot(dir, command: 'blast-radius', stderr: stderr)).to be_nil
        expect(stderr.string).to include("blast-radius: no cache yet at #{dir} -- run rspec first")
      end
    end

    it 'prints a prefixed incompatibility message and returns nil on schema mismatch' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'last_run.json'),
                   JSON.dump('schema_version' => 9999, 'run_id' => 'stale_run'))
        allow(RSpecTracer).to receive(:storage_backend).and_return(:json)
        expect(described_class.load_snapshot(dir, command: 'explain', stderr: stderr)).to be_nil
        expect(stderr.string)
          .to include("explain: cache at #{dir} is incompatible with this rspec-tracer; next rspec run is cold")
      end
    end

    it 'returns the snapshot and the backend it was loaded through on success' do
      Dir.mktmpdir do |dir|
        snapshot = RSpecTracer::Storage::Snapshot.empty(
          schema_version: RSpecTracer::Storage::Schema::CURRENT, run_id: 'run_helpers'
        )
        snapshot.all_examples = { 'a/spec.rb[1:1]' => { 'example_id' => 'a/spec.rb[1:1]' } }
        RSpecTracer::Storage::JsonBackend.new(cache_path: dir).save_graph(
          snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT
        )
        allow(RSpecTracer).to receive(:storage_backend).and_return(:json)

        loaded = described_class.load_snapshot(dir, command: 'explain', stderr: stderr)
        expect(loaded).not_to be_nil
        loaded_snapshot, backend = loaded
        expect(loaded_snapshot.all_examples.keys).to eq(['a/spec.rb[1:1]'])
        expect(backend).to be_a(RSpecTracer::Storage::JsonBackend)
        expect(stderr.string).to be_empty
      end
    end
  end

  describe '.filter_decisions_persisted?' do
    it 'is true for the json backend, which persists filtered_examples' do
      Dir.mktmpdir do |dir|
        backend = RSpecTracer::Storage::JsonBackend.new(cache_path: dir)
        expect(described_class.filter_decisions_persisted?(backend)).to be(true)
      end
    end

    it 'is false for any backend that does not persist filter decisions (e.g. sqlite)' do
      expect(described_class.filter_decisions_persisted?(Object.new)).to be(false)
    end
  end

  describe '.fetch_meta' do
    # Regression: post-#182 msgpack preserves Symbol keys end-to-end;
    # JSON-deserialized caches yield String keys. CLI helpers must
    # tolerate either shape.
    it 'reads through String keys' do
      expect(described_class.fetch_meta({ 'full_description' => 'x' }, 'full_description')).to eq('x')
    end

    it 'reads through Symbol keys when the value lives under one' do
      expect(described_class.fetch_meta({ full_description: 'x' }, 'full_description')).to eq('x')
    end

    it 'returns the first non-nil match across alternatives' do
      expect(described_class.fetch_meta({ description: 'y' }, 'full_description', 'description')).to eq('y')
    end

    it 'returns nil when no alternative matches' do
      expect(described_class.fetch_meta({}, 'full_description')).to be_nil
    end
  end

  describe '.dig_meta' do
    it 'digs through nested String keys' do
      meta = { 'execution_result' => { 'status' => 'passed' } }
      expect(described_class.dig_meta(meta, 'execution_result', 'status')).to eq('passed')
    end

    it 'digs through mixed String/Symbol levels' do
      meta = { 'execution_result' => { status: 'failed' } }
      expect(described_class.dig_meta(meta, 'execution_result', 'status')).to eq('failed')
    end

    it 'returns nil when an intermediate level is missing or not a Hash' do
      expect(described_class.dig_meta({}, 'execution_result', 'status')).to be_nil
      expect(described_class.dig_meta({ 'execution_result' => 'oops' }, 'execution_result', 'status')).to be_nil
    end
  end

  describe '.example_location' do
    it 'prefers the rerun_* fields' do
      meta = {
        'rerun_file_name' => './spec/a_spec.rb', 'rerun_line_number' => 3,
        'file_name' => './spec/other.rb', 'line_number' => 99
      }
      expect(described_class.example_location(meta)).to eq(['./spec/a_spec.rb', 3])
    end

    it 'falls back to file_name/line_number' do
      meta = { 'file_name' => './spec/b_spec.rb', 'line_number' => 7 }
      expect(described_class.example_location(meta)).to eq(['./spec/b_spec.rb', 7])
    end

    it 'returns nils when the meta has no location fields' do
      expect(described_class.example_location({})).to eq([nil, nil])
    end
  end

  describe '.example_description' do
    it 'prefers full_description and falls back to description' do
      expect(described_class.example_description({ 'full_description' => 'A' })).to eq('A')
      expect(described_class.example_description({ 'description' => 'B' })).to eq('B')
      expect(described_class.example_description({})).to be_nil
    end
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
