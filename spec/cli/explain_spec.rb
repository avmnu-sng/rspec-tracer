# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'set'

require 'rspec_tracer/cli/explain'
require 'rspec_tracer/storage/json_backend'
require 'rspec_tracer/storage/snapshot'
require 'rspec_tracer/storage/schema'

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/InstanceVariable
RSpec.describe RSpecTracer::CLI::Explain do
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  describe '.run' do
    it 'prints help when no args given' do
      expect(described_class.run([], stdout: stdout, stderr: stderr)).to eq(0)
      expect(stdout.string).to include('Usage: rspec-tracer explain')
    end

    it 'prints help on -h / --help' do
      %w[-h --help].each do |flag|
        out = StringIO.new
        expect(described_class.run([flag], stdout: out, stderr: stderr)).to eq(0)
        expect(out.string).to include('Usage: rspec-tracer explain')
      end
    end

    it 'returns 1 with a clear error when no cache exists' do
      Dir.mktmpdir do |dir|
        allow(RSpecTracer).to receive_messages(cache_path: dir, storage_backend: :json)
        expect(described_class.run(%w[anything], stdout: stdout, stderr: stderr)).to eq(1)
        expect(stderr.string).to include('no cache yet')
      end
    end

    it 'returns 1 when the cache is schema-mismatched' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'last_run.json'),
                   JSON.dump('schema_version' => 9999, 'run_id' => 'stale_run'))
        allow(RSpecTracer).to receive_messages(cache_path: dir, storage_backend: :json)
        expect(described_class.run(%w[any], stdout: stdout, stderr: stderr)).to eq(1)
        expect(stderr.string).to include('incompatible')
      end
    end

    context 'with a populated cache (json backend)' do
      let(:run_id) { 'run_xyz' }
      let(:example_meta) do
        {
          'example_id' => 'a/spec.rb[1:1]',
          'full_description' => 'Foo does bar',
          'rerun_file_name' => './spec/foo_spec.rb',
          'rerun_line_number' => 12,
          'execution_result' => { 'status' => 'passed' },
          'run_reason' => 'changed'
        }
      end

      before do
        @tmp_dir = Dir.mktmpdir
        snapshot = RSpecTracer::Storage::Snapshot.empty(
          schema_version: RSpecTracer::Storage::Schema::CURRENT, run_id: run_id
        )
        snapshot.all_examples = { 'a/spec.rb[1:1]' => example_meta }
        snapshot.dependency = { 'a/spec.rb[1:1]' => Set.new(['./spec/foo_spec.rb', './lib/foo.rb']) }
        RSpecTracer::Storage::JsonBackend.new(cache_path: @tmp_dir).save_graph(
          snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT
        )
        allow(RSpecTracer).to receive_messages(cache_path: @tmp_dir, storage_backend: :json)
      end

      after { FileUtils.rm_rf(@tmp_dir) if @tmp_dir }

      it 'returns 1 when no example matches the query' do
        expect(described_class.run(%w[totally_bogus], stdout: stdout, stderr: stderr)).to eq(1)
        expect(stderr.string).to include('no example matching')
      end

      it 'matches by exact example_id and prints the full explanation' do
        expect(described_class.run(['a/spec.rb[1:1]'], stdout: stdout, stderr: stderr)).to eq(0)
        expect(stdout.string).to include('Foo does bar')
        expect(stdout.string).to include('passed')
        expect(stdout.string).to include('changed')
        expect(stdout.string).to include('./lib/foo.rb')
      end

      it 'falls back to substring match on full_description' do
        expect(described_class.run(%w[Foo], stdout: stdout, stderr: stderr)).to eq(0)
        expect(stdout.string).to include('Foo does bar')
      end
    end

    context 'with a populated cache (sqlite backend)', :sqlite do
      let(:run_id) { 'run_sqlite_xyz' }

      before do
        skip 'sqlite backend unavailable on this Ruby' unless sqlite_available?
        @tmp_dir = Dir.mktmpdir
        snapshot = RSpecTracer::Storage::Snapshot.empty(
          schema_version: RSpecTracer::Storage::Schema::CURRENT, run_id: run_id
        )
        snapshot.all_examples = {
          'a/spec.rb[1:1]' => {
            'example_id' => 'a/spec.rb[1:1]',
            'full_description' => 'Foo does bar',
            'rerun_file_name' => './spec/foo_spec.rb',
            'rerun_line_number' => 12,
            'execution_result' => { 'status' => 'passed' },
            'run_reason' => 'changed'
          }
        }
        snapshot.dependency = { 'a/spec.rb[1:1]' => Set.new(['./spec/foo_spec.rb', './lib/foo.rb']) }
        RSpecTracer::Storage::SqliteBackend.new(cache_path: @tmp_dir).save_graph(
          snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT
        )
        allow(RSpecTracer).to receive_messages(cache_path: @tmp_dir, storage_backend: :sqlite)
      end

      after { FileUtils.rm_rf(@tmp_dir) if @tmp_dir }

      # Regression for #183: the CLI must load the snapshot through
      # the backend protocol (sqlite's LazySnapshot) and resolve
      # all_examples + dependency from there, not the JsonBackend
      # `last_run.json` + per-field-file layout.
      it 'resolves example metadata + dependency under storage_backend :sqlite' do
        expect(described_class.run(['a/spec.rb[1:1]'], stdout: stdout, stderr: stderr)).to eq(0)
        expect(stdout.string).to include('Foo does bar')
        expect(stdout.string).to include('./lib/foo.rb')
      end

      def sqlite_available?
        return false unless RUBY_ENGINE == 'ruby'

        require 'sqlite3'
        require 'rspec_tracer/storage/sqlite_backend'
        true
      rescue LoadError
        false
      end
    end

    it 'rescues StandardError and returns 1' do
      allow(RSpecTracer).to receive(:cache_path).and_raise(StandardError, 'cache resolve boom')

      expect(described_class.run(%w[any], stdout: stdout, stderr: stderr)).to eq(1)
      expect(stderr.string).to include('explain:')
      expect(stderr.string).to include('boom')
    end
  end

  describe '.find_example' do
    let(:examples) do
      {
        'a' => { 'full_description' => 'Foo does bar' },
        'b' => { 'full_description' => 'Baz works correctly' }
      }
    end

    it 'returns the meta on exact id match' do
      expect(described_class.find_example(examples, 'a')).to eq(examples['a'])
    end

    it 'returns the meta on substring match against description' do
      expect(described_class.find_example(examples, 'Baz')).to eq(examples['b'])
    end

    it 'returns nil on no match' do
      expect(described_class.find_example(examples, 'totally_unrelated')).to be_nil
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
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/InstanceVariable
