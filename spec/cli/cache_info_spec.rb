# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'set'

require 'rspec_tracer/cli/cache_info'
require 'rspec_tracer/storage/json_backend'
require 'rspec_tracer/storage/snapshot'
require 'rspec_tracer/storage/schema'

# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/InstanceVariable
RSpec.describe RSpecTracer::CLI::CacheInfo do
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  describe '.run' do
    it 'prints help on -h / --help' do
      %w[-h --help].each do |flag|
        out = StringIO.new
        expect(described_class.run([flag], stdout: out, stderr: stderr)).to eq(0)
        expect(out.string).to include('Usage: rspec-tracer cache:info')
      end
    end

    it 'exits 0 silently when a downstream pipe closes early (broken pipe from `| head`)' do
      broken = StringIO.new
      allow(broken).to receive(:puts).and_raise(Errno::EPIPE)
      expect(described_class.run(%w[-h], stdout: broken, stderr: stderr)).to eq(0)
      expect(stderr.string).to be_empty
    end

    context 'with a populated cache (json backend)' do
      before do
        @tmp_dir = Dir.mktmpdir
        snapshot = RSpecTracer::Storage::Snapshot.empty(
          schema_version: RSpecTracer::Storage::Schema::CURRENT, run_id: 'run_abc123'
        )
        snapshot.all_examples = { 'a' => { 'description' => 'one' }, 'b' => { 'description' => 'two' } }
        RSpecTracer::Storage::JsonBackend.new(cache_path: @tmp_dir).save_graph(
          snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT
        )
        allow(RSpecTracer).to receive_messages(cache_path: @tmp_dir, storage_backend: :json)
      end

      after { FileUtils.rm_rf(@tmp_dir) if @tmp_dir }

      it 'prints cache_path, size, last_run id, and example count' do
        expect(described_class.run([], stdout: stdout, stderr: stderr)).to eq(0)
        expect(stdout.string).to include('cache_path:')
        expect(stdout.string).to include('size:')
        expect(stdout.string).to include('last_run:   run_abc123')
        expect(stdout.string).to include('examples:   2 tracked')
      end
    end

    context 'with a populated cache (sqlite backend)', :sqlite do
      before do
        skip 'sqlite backend unavailable on this Ruby' unless sqlite_available?
        @tmp_dir = Dir.mktmpdir
        snapshot = RSpecTracer::Storage::Snapshot.empty(
          schema_version: RSpecTracer::Storage::Schema::CURRENT, run_id: 'run_sqlite_xyz'
        )
        snapshot.all_examples = { 'a' => { 'description' => 'one' }, 'b' => { 'description' => 'two' } }
        RSpecTracer::Storage::SqliteBackend.new(cache_path: @tmp_dir).save_graph(
          snapshot, schema_version: RSpecTracer::Storage::Schema::CURRENT
        )
        allow(RSpecTracer).to receive_messages(cache_path: @tmp_dir, storage_backend: :sqlite)
      end

      after { FileUtils.rm_rf(@tmp_dir) if @tmp_dir }

      # Regression for #183: the CLI must read the latest run via
      # backend.last_run_id (sqlite's meta table), not assume the
      # JsonBackend on-disk last_run.json layout.
      it 'resolves last_run + example count under storage_backend :sqlite' do
        expect(described_class.run([], stdout: stdout, stderr: stderr)).to eq(0)
        expect(stdout.string).to include('last_run:   run_sqlite_xyz')
        expect(stdout.string).to include('examples:   2 tracked')
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

    context 'with no cache' do
      it 'reports the empty-cache state and exits 0' do
        Dir.mktmpdir do |dir|
          allow(RSpecTracer).to receive_messages(cache_path: dir, storage_backend: :json)
          expect(described_class.run([], stdout: stdout, stderr: stderr)).to eq(0)
          expect(stdout.string).to include('no cache yet')
        end
      end
    end

    context 'with a cache whose schema_version does not match the gem' do
      # last_run_id resolves (the stored run is real), but load_graph
      # returns nil because the schema doesn't match Schema::CURRENT.
      # The CLI must surface the mismatch without crashing or printing
      # a misleading example count.
      it 'prints the schema-mismatch banner and exits 0' do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, 'last_run.json'),
                     JSON.dump('schema_version' => 9999, 'run_id' => 'stale_run'))
          allow(RSpecTracer).to receive_messages(cache_path: dir, storage_backend: :json)

          expect(described_class.run([], stdout: stdout, stderr: stderr)).to eq(0)
          expect(stdout.string).to include('last_run:   stale_run')
          expect(stdout.string).to include('schema mismatch')
        end
      end
    end

    it 'rescues StandardError and returns 1 with a clear error' do
      allow(RSpecTracer).to receive(:cache_path).and_raise(StandardError, 'cache resolve boom')

      expect(described_class.run([], stdout: stdout, stderr: stderr)).to eq(1)
      expect(stderr.string).to include('cache:info:')
      expect(stderr.string).to include('boom')
    end
  end

  describe '.format_bytes' do
    it 'returns 0 B for zero or negative input' do
      expect(described_class.format_bytes(0)).to eq('0 B')
      expect(described_class.format_bytes(-1)).to eq('0 B')
    end

    it 'formats bytes / KB / MB / GB with one decimal' do
      expect(described_class.format_bytes(500)).to eq('500.0 B')
      expect(described_class.format_bytes(2_048)).to eq('2.0 KB')
      expect(described_class.format_bytes(5 * 1024 * 1024)).to eq('5.0 MB')
      expect(described_class.format_bytes(3 * 1024 * 1024 * 1024)).to eq('3.0 GB')
    end
  end

  describe '.directory_size' do
    it 'returns 0 for non-existent paths' do
      expect(described_class.directory_size('/nope/does/not/exist')).to eq(0)
    end

    it 'sums file sizes recursively' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'a.txt'), 'x' * 100)
        FileUtils.mkdir_p(File.join(dir, 'sub'))
        File.write(File.join(dir, 'sub', 'b.txt'), 'y' * 200)

        expect(described_class.directory_size(dir)).to eq(300)
      end
    end
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations, RSpec/InstanceVariable
