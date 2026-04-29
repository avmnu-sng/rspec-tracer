# frozen_string_literal: true

# Read-only cache filesystem - graceful degradation across the
# storage layer + the engine's run_finalize path. The architecture
# contract (docs/revamp/ARCHITECTURE.md §Cache corruption recovery)
# says "Never propagate storage errors to the caller" - so a
# read-only cache_path must NOT crash the user's test suite.
#
#   - Storage backends: save_graph raises Errno::EACCES (or
#     SQLite3::CantOpenException for SqliteBackend) on a read-only
#     cache_path. Reads work fine; the prior valid run stays
#     loadable.
#   - Engine integration (RSpecTracer.run_finalize): the rescue
#     added in M8.2 logs + returns nil instead of propagating, so
#     the at_exit pipeline downstream skips reports and the test
#     suite exits cleanly.
#
# Skip on Windows (chmod semantics differ) - we don't support
# Windows per COMPATIBILITY_MATRIX.md anyway, but be explicit.

return if Gem.win_platform?

require 'fileutils'
require 'json'
require 'logger'
require 'set'
require 'tmpdir'
require 'rspec_tracer'
require 'rspec_tracer/storage/json_backend'
require 'rspec_tracer/storage/snapshot'

READONLY_FS_SQLITE_AVAILABLE =
  begin
    require 'sqlite3'
    require 'rspec_tracer/storage/sqlite_backend'
    RUBY_ENGINE == 'ruby'
  rescue LoadError
    false
  end

# rubocop:disable RSpec/DescribeClass
RSpec.describe 'Read-only filesystem — graceful degradation' do
  let(:tmp_base) { Dir.mktmpdir('rspec_tracer_readonly_') }
  let(:cache_path) { File.join(tmp_base, 'cache') }
  let(:schema_version) { RSpecTracer::Storage::Schema::CURRENT }

  # Restore writable mode before rm_rf — chmod 0o555 makes Dir.unlink
  # itself fail unless the parent dir's mode allows it. The chmod 0o755
  # cleanup runs in `after` regardless of test outcome.
  after do
    FileUtils.chmod_R(0o755, tmp_base) if File.directory?(tmp_base)
    FileUtils.rm_rf(tmp_base)
  end

  def build_snapshot(run_id, marker)
    RSpecTracer::Storage::Snapshot.new(
      schema_version: RSpecTracer::Storage::Schema::CURRENT,
      run_id: run_id,
      all_examples: { marker => { id: marker, description: "from #{marker}" } },
      duplicate_examples: {},
      interrupted_examples: Set.new,
      flaky_examples: Set.new,
      failed_examples: Set.new,
      pending_examples: Set.new,
      skipped_examples: Set.new,
      all_files: { '/a.rb' => { file_name: '/a.rb', file_path: '/tmp/a.rb', digest: 'abc' } },
      dependency: { marker => Set.new(['/a.rb']) },
      reverse_dependency: { '/a.rb' => Set.new([marker]) },
      examples_coverage: { marker => { '/a.rb' => [1] } },
      boot_set: {},
      wsi_snapshot: {},
      env_snapshot: {},
      env_dependency: {}
    )
  end

  describe 'JsonBackend' do
    let(:backend) { RSpecTracer::Storage::JsonBackend.new(cache_path: cache_path) }

    before do
      backend.save_graph(build_snapshot('alpha', 'ex_a'), schema_version: schema_version)
      FileUtils.chmod_R(0o555, cache_path)
    end

    it 'raises EACCES from save_graph on a read-only cache_path' do
      expect do
        backend.save_graph(build_snapshot('beta', 'ex_b'), schema_version: schema_version)
      end.to raise_error(Errno::EACCES)
    end

    it 'still serves load_graph from a read-only cache_path (reads do not need write)' do
      reader = RSpecTracer::Storage::JsonBackend.new(cache_path: cache_path)
      snap = reader.load_graph(schema_version: schema_version)

      expect(snap).not_to be_nil
      expect(snap.run_id).to eq('alpha')
    end

    it 'leaves the prior valid run intact after a failed save attempt' do
      begin
        backend.save_graph(build_snapshot('beta', 'ex_b'), schema_version: schema_version)
      rescue Errno::EACCES
        # expected — covered by the prior example
      end

      reader = RSpecTracer::Storage::JsonBackend.new(cache_path: cache_path)
      snap = reader.load_graph(schema_version: schema_version)
      expect(snap.run_id).to eq('alpha')
    end
  end

  describe 'SqliteBackend' do
    before do
      skip 'sqlite3 gem not installable on this Ruby (JRuby or missing dep)' unless READONLY_FS_SQLITE_AVAILABLE
      backend.save_graph(build_snapshot('alpha', 'ex_a'), schema_version: schema_version)
      FileUtils.chmod_R(0o555, cache_path)
    end

    let(:backend) { RSpecTracer::Storage::SqliteBackend.new(cache_path: cache_path) }

    it 'raises a SQLite3 / SystemCallError on save_graph against a read-only cache_path' do
      expect do
        backend.save_graph(build_snapshot('beta', 'ex_b'), schema_version: schema_version)
      end.to raise_error(StandardError) { |e|
        expect(e).to be_a(SQLite3::Exception).or be_a(SystemCallError)
      }
    end

    it 'still serves load_graph from a read-only cache_path' do
      reader = RSpecTracer::Storage::SqliteBackend.new(cache_path: cache_path)
      snap = reader.load_graph(schema_version: schema_version)

      expect(snap).not_to be_nil
      expect(snap.run_id).to eq('alpha')
    end
  end

  describe 'engine integration — run_finalize rescue' do
    # Stubs the dependent surface around RSpecTracer.run_finalize so the
    # rescue contract is observable without spinning up a full engine
    # against a real read-only fs. The realistic invariant: if
    # engine.finalize raises any StandardError, run_finalize swallows
    # + logs + returns nil so emit_reporters skips and the at_exit
    # pipeline carries on.

    it 'returns nil + logs when engine.finalize raises Errno::EACCES (read-only fs simulation)' do
      fake_engine = instance_double(RSpecTracer::Engine)
      fake_logger = instance_double(Logger)

      allow(RSpecTracer).to receive_messages(engine: fake_engine, logger: fake_logger)
      allow(fake_engine).to receive(:finalize).and_raise(Errno::EACCES, 'permission denied')
      allow(fake_logger).to receive(:warn)
      allow(fake_logger).to receive(:debug)

      result = RSpecTracer.send(:run_finalize)

      expect(result).to be_nil
      expect(fake_logger).to have_received(:warn).with(/cache persistence failed.*Errno::EACCES.*permission denied/)
    end

    it 'returns nil + logs when engine.finalize raises a SQLite3::Exception' do
      skip 'sqlite3 gem not installable on this Ruby' unless READONLY_FS_SQLITE_AVAILABLE

      fake_engine = instance_double(RSpecTracer::Engine)
      fake_logger = instance_double(Logger)

      allow(RSpecTracer).to receive_messages(engine: fake_engine, logger: fake_logger)
      allow(fake_engine).to receive(:finalize).and_raise(SQLite3::Exception, 'database is locked')
      allow(fake_logger).to receive(:warn)
      allow(fake_logger).to receive(:debug)

      expect(RSpecTracer.send(:run_finalize)).to be_nil
      expect(fake_logger).to have_received(:warn).with(/cache persistence failed.*SQLite3::Exception/)
    end
  end
end
# rubocop:enable RSpec/DescribeClass
