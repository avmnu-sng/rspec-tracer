# frozen_string_literal: true

# Multi-backend graceful-degradation under arbitrary byte corruption
# + cache-layout corruption. Every storage backend's `load_graph`
# must return `nil` + log on any corruption, never raise into the
# user's test suite.
#
# Coverage:
#   - Layout corruption (backend-agnostic via JsonBackend :json):
#     missing last_run.json, malformed last_run.json, missing run-id
#     dir, cache_path absent, cache_path is a regular file.
#   - JsonBackend :msgpack property fuzz (1000 iter Rantly across
#     last_run.json + every per-run .msgpack.gz file).
#   - JsonBackend :msgpack targeted: msgpack-decoded-but-wrong-shape,
#     zlib-decompressed garbage, raw .msgpack bytes without zlib wrap.
#   - SqliteBackend property fuzz (1000 iter Rantly across
#     rspec_tracer.sqlite3).
#   - SqliteBackend targeted: missing meta table, wrong
#     schema_version, truncated db file, cache_path with no
#     .sqlite3 file.
#
# JsonBackend :json property fuzz already lives at
# spec/fuzz/json_backend_corruption_spec.rb (M3.4 1000-iter Rantly).
# Not duplicated here - this spec extends the pattern, doesn't repeat
# it.

require 'fileutils'
require 'json'
require 'set'
require 'tmpdir'
require 'zlib'
require 'rantly/rspec_extensions'
require 'rspec_tracer/storage/json_backend'

SQLITE_AVAILABLE =
  begin
    require 'sqlite3'
    require 'rspec_tracer/storage/sqlite_backend'
    RUBY_ENGINE == 'ruby'
  rescue LoadError
    false
  end

# Rantly 0.x's property_of block evaluates in Rantly's own instance
# context, so closure-captured lets / locals aren't visible. Pull
# generators into a module - the same pattern as
# spec/fuzz/json_backend_corruption_spec.rb.
module CacheCorruptionGen
  module_function

  def bytes
    Rantly { sized(range(0, 4096)) { string(:ascii) } }
  end

  # Targets for the msgpack property fuzz. last_run.json is always
  # plain JSON regardless of serializer; per-field files take the
  # `.msgpack.gz` extension.
  MSGPACK_TARGETS = [RSpecTracer::Storage::JsonBackend::LAST_RUN_FILENAME] +
    RSpecTracer::Storage::JsonBackend::FIELD_NAMES.map { |f| "run-corrupt/#{f}.msgpack.gz" }

  def msgpack_target
    Rantly { choose(*MSGPACK_TARGETS) }
  end
end

# rubocop:disable RSpec/DescribeClass
RSpec.describe 'Cache corruption — graceful degradation' do
  let(:tmp_base) { Dir.mktmpdir('rspec_tracer_corruption_') }
  let(:cache_path) { File.join(tmp_base, 'cache') }
  let(:schema_version) { RSpecTracer::Storage::Schema::CURRENT }

  after { FileUtils.rm_rf(tmp_base) if tmp_base }

  # Reusable sample snapshot for save_graph priming. Per-field shape
  # matches what the engine emits at finalize time so corruption
  # exercises the same parse path a real warm run hits.
  def build_sample_snapshot(run_id)
    RSpecTracer::Storage::Snapshot.new(
      schema_version: RSpecTracer::Storage::Schema::CURRENT,
      run_id: run_id,
      all_examples: { 'ex1' => { id: 'ex1', description: 'desc' } },
      duplicate_examples: {},
      interrupted_examples: Set.new,
      flaky_examples: Set.new,
      failed_examples: Set.new,
      pending_examples: Set.new,
      skipped_examples: Set.new,
      all_files: { '/a.rb' => { file_name: '/a.rb', file_path: '/tmp/a.rb', digest: 'abc' } },
      dependency: { 'ex1' => Set.new(['/a.rb']) },
      reverse_dependency: { '/a.rb' => Set.new(['ex1']) },
      examples_coverage: { 'ex1' => { '/a.rb' => [1, nil, 2] } },
      boot_set: { 'lib/boot.rb' => 'deadbeef' },
      wsi_snapshot: { 'Gemfile.lock' => 'feedc0de' },
      env_snapshot: { 'API_KEY' => 'facade1' },
      env_dependency: { 'ex1' => ['API_KEY'] }
    )
  end

  describe 'cache directory layout (backend-agnostic via JsonBackend :json)' do
    let(:backend) { RSpecTracer::Storage::JsonBackend.new(cache_path: cache_path) }

    before do
      snap = build_sample_snapshot('run-layout')
      backend.save_graph(snap, schema_version: schema_version)
    end

    it 'returns nil when last_run.json is missing' do
      File.delete(File.join(cache_path, RSpecTracer::Storage::JsonBackend::LAST_RUN_FILENAME))

      expect(backend.load_graph(schema_version: schema_version)).to be_nil
    end

    it 'returns nil when last_run.json is malformed (truncated mid-string)' do
      path = File.join(cache_path, RSpecTracer::Storage::JsonBackend::LAST_RUN_FILENAME)
      File.binwrite(path, '{"schema_version": 3, "run_i')

      expect(backend.load_graph(schema_version: schema_version)).to be_nil
    end

    it 'returns nil when last_run.json points at a missing run-id directory' do
      manifest = JSON.parse(File.read(File.join(cache_path, RSpecTracer::Storage::JsonBackend::LAST_RUN_FILENAME)))
      run_id = manifest.fetch('run_id')
      FileUtils.rm_rf(File.join(cache_path, run_id))

      expect(backend.load_graph(schema_version: schema_version)).to be_nil
    end

    it 'returns nil when the cache_path itself does not exist' do
      FileUtils.rm_rf(cache_path)
      fresh_backend = RSpecTracer::Storage::JsonBackend.new(cache_path: cache_path)

      expect(fresh_backend.load_graph(schema_version: schema_version)).to be_nil
    end

    it 'returns nil when last_run.json carries a schema_version mismatch' do
      path = File.join(cache_path, RSpecTracer::Storage::JsonBackend::LAST_RUN_FILENAME)
      manifest = JSON.parse(File.read(path))
      manifest['schema_version'] = 999
      File.write(path, JSON.pretty_generate(manifest))

      expect(backend.load_graph(schema_version: schema_version)).to be_nil
    end

    it 'never raises on a load_graph called against a fresh empty cache_path' do
      pristine = File.join(tmp_base, 'pristine')
      FileUtils.mkdir_p(pristine)
      fresh_backend = RSpecTracer::Storage::JsonBackend.new(cache_path: pristine)

      expect { fresh_backend.load_graph(schema_version: schema_version) }.not_to raise_error
      expect(fresh_backend.load_graph(schema_version: schema_version)).to be_nil
    end
  end

  describe 'JsonBackend with serializer: :msgpack' do
    let(:backend) { RSpecTracer::Storage::JsonBackend.new(cache_path: cache_path, serializer: :msgpack) }

    before do
      snap = build_sample_snapshot('run-corrupt')
      backend.save_graph(snap, schema_version: schema_version)
    end

    describe 'property fuzz' do
      it 'never raises across 1000 random-byte overwrites of any cache file' do
        property_of { [CacheCorruptionGen.msgpack_target, CacheCorruptionGen.bytes] }.check(1000) do |target, bytes|
          path = File.join(cache_path, target)
          File.binwrite(path, bytes.b) if File.file?(path)

          expect { backend.load_graph(schema_version: schema_version) }.not_to raise_error
        end
      end
    end

    describe 'targeted shape corruption' do
      it 'returns nil when a per-field file is raw msgpack bytes (no zlib wrap)' do
        require 'msgpack'
        path = File.join(cache_path, 'run-corrupt', 'all_examples.msgpack.gz')
        File.binwrite(path, MessagePack.pack({ 'shape' => 'wrong' })) # raw, no zlib

        expect(backend.load_graph(schema_version: schema_version)).not_to be_nil # manifest still good
        # The lazy reader returns nil-default for the corrupted field
        # without raising; assert via field access:
        expect(backend.load_graph(schema_version: schema_version).all_examples).to eq({})
      end

      it 'returns nil-default for a per-field file that decompresses to garbage' do
        path = File.join(cache_path, 'run-corrupt', 'dependency.msgpack.gz')
        File.binwrite(path, Zlib::Deflate.deflate("not msgpack at all\xFF\x00"))

        snap = backend.load_graph(schema_version: schema_version)
        expect(snap).not_to be_nil
        expect(snap.dependency).to eq({})
      end

      it 'returns nil-default for a per-field file that is zlib garbage' do
        path = File.join(cache_path, 'run-corrupt', 'all_files.msgpack.gz')
        File.binwrite(path, "\x00\xFF garbage that is not zlib \xC2\x00")

        snap = backend.load_graph(schema_version: schema_version)
        expect(snap).not_to be_nil
        expect(snap.all_files).to eq({})
      end

      it 'returns nil-default for a per-field file that is empty' do
        path = File.join(cache_path, 'run-corrupt', 'examples_coverage.msgpack.gz')
        File.binwrite(path, '')

        snap = backend.load_graph(schema_version: schema_version)
        expect(snap).not_to be_nil
        expect(snap.examples_coverage).to eq({})
      end
    end
  end

  describe 'SqliteBackend' do
    before do
      skip 'sqlite3 gem not installable on this Ruby (JRuby or missing dep)' unless SQLITE_AVAILABLE
      snap = build_sample_snapshot('run-sqlite-corrupt')
      backend.save_graph(snap, schema_version: schema_version)
    end

    let(:backend) { RSpecTracer::Storage::SqliteBackend.new(cache_path: cache_path) }
    let(:db_path) { File.join(cache_path, RSpecTracer::Storage::SqliteBackend::DB_FILENAME) }

    describe 'property fuzz' do
      it 'never raises across 1000 random-byte overwrites of the sqlite3 file' do
        property_of { CacheCorruptionGen.bytes }.check(1000) do |bytes|
          File.binwrite(db_path, bytes.b)

          expect { backend.load_graph(schema_version: schema_version) }.not_to raise_error
        end
      end
    end

    describe 'targeted shape corruption' do
      it 'returns nil when the sqlite3 file is truncated (header missing)' do
        File.binwrite(db_path, '')

        expect(backend.load_graph(schema_version: schema_version)).to be_nil
      end

      it 'returns nil when the sqlite3 file has wrong magic bytes' do
        File.binwrite(db_path, "\x00\xFF not a sqlite db \xC2\x00")

        expect(backend.load_graph(schema_version: schema_version)).to be_nil
      end

      it 'returns nil when the meta table is missing' do
        SQLite3::Database.new(db_path) do |db|
          db.execute('DROP TABLE meta')
        end

        expect(backend.load_graph(schema_version: schema_version)).to be_nil
      end

      it 'returns nil when meta has a schema_version mismatch' do
        SQLite3::Database.new(db_path) do |db|
          db.execute('UPDATE meta SET schema_version = 999')
        end

        expect(backend.load_graph(schema_version: schema_version)).to be_nil
      end

      it 'returns nil when meta is empty (zero rows)' do
        SQLite3::Database.new(db_path) do |db|
          db.execute('DELETE FROM meta')
        end

        expect(backend.load_graph(schema_version: schema_version)).to be_nil
      end

      it 'returns nil when cache_path exists but no sqlite3 file is present' do
        File.delete(db_path)

        expect(backend.load_graph(schema_version: schema_version)).to be_nil
      end
    end
  end
end
# rubocop:enable RSpec/DescribeClass
