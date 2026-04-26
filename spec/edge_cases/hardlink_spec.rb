# frozen_string_literal: true

# Hardlinks: two distinct path strings backed by the same inode +
# byte content. Tracker-level dedup ("treat as same file") is the
# responsibility of higher layers; the storage layer's contract
# is to preserve whatever the tracker recorded - opaque path keys
# in / opaque path keys out.
#
# Filesystem semantics under test:
#   - File.link creates a second path entry pointing at the same
#     inode. File.stat(p1).ino == File.stat(p2).ino.
#   - SHA256.file returns identical bytes through either path
#     (it reads file content, not metadata).
#   - Modifying content via one path is visible via the other
#     (single-inode invariant).
#
# Storage contract:
#   - Both paths round-trip as distinct all_files keys.
#   - Both paths can independently appear in dependency /
#     reverse_dependency.
#
# Hardlink support: Linux + macOS native filesystems yes; Windows
# yes only on NTFS with admin (we don't support Windows). Skip on
# Windows for safety.

return if Gem.win_platform?

require 'digest'
require 'fileutils'
require 'set'
require 'tmpdir'
require 'rspec_tracer/storage/json_backend'
require 'rspec_tracer/storage/snapshot'

# rubocop:disable RSpec/DescribeClass, RSpec/MultipleMemoizedHelpers
RSpec.describe 'Hardlinks in cache content + filesystem semantics' do
  let(:tmp_base) { Dir.mktmpdir('rspec_tracer_hardlink_') }
  let(:cache_path) { File.join(tmp_base, 'cache') }
  let(:schema_version) { RSpecTracer::Storage::Schema::CURRENT }

  after { FileUtils.rm_rf(tmp_base) if tmp_base }

  describe 'filesystem behavior under File.link' do
    it 'creates a second path with the same inode + content' do
      original = File.join(tmp_base, 'original.rb')
      hardlink = File.join(tmp_base, 'hardlink.rb')
      File.write(original, "puts 'shared'\n")
      File.link(original, hardlink)

      expect(File.stat(original).ino).to eq(File.stat(hardlink).ino)
      expect(File.read(hardlink)).to eq(File.read(original))
    end

    it 'returns identical SHA256 through either path' do
      original = File.join(tmp_base, 'original.rb')
      hardlink = File.join(tmp_base, 'hardlink.rb')
      File.write(original, "x = 1\n")
      File.link(original, hardlink)

      expect(Digest::SHA256.file(hardlink).hexdigest).to eq(Digest::SHA256.file(original).hexdigest)
    end

    it 'reflects content edits via either path back through the other' do
      original = File.join(tmp_base, 'original.rb')
      hardlink = File.join(tmp_base, 'hardlink.rb')
      File.write(original, "first\n")
      File.link(original, hardlink)

      File.write(hardlink, "second\n")

      expect(File.read(original)).to eq("second\n")
    end

    it 'survives unlinking the original — hardlink keeps the inode alive' do
      original = File.join(tmp_base, 'original.rb')
      hardlink = File.join(tmp_base, 'hardlink.rb')
      File.write(original, "alive\n")
      File.link(original, hardlink)
      File.delete(original)

      expect(File).not_to exist(original)
      expect(File.read(hardlink)).to eq("alive\n")
    end
  end

  describe 'storage round-trip' do
    let(:original_path) { '/spec/support/shared.rb' }
    let(:hardlink_path) { '/spec/support/aliased_shared.rb' }

    def build_hardlink_snapshot(run_id)
      digest = 'shared-content-digest-abc'
      RSpecTracer::Storage::Snapshot.new(
        schema_version: RSpecTracer::Storage::Schema::CURRENT,
        run_id: run_id,
        all_examples: { 'ex_a' => { id: 'ex_a', description: 'depends on the hardlinked pair' } },
        duplicate_examples: {},
        interrupted_examples: Set.new,
        flaky_examples: Set.new,
        failed_examples: Set.new,
        pending_examples: Set.new,
        skipped_examples: Set.new,
        all_files: {
          original_path => { file_name: original_path, file_path: original_path, digest: digest },
          hardlink_path => { file_name: hardlink_path, file_path: hardlink_path, digest: digest }
        },
        dependency: { 'ex_a' => Set.new([original_path, hardlink_path]) },
        reverse_dependency: {
          original_path => Set.new(['ex_a']),
          hardlink_path => Set.new(['ex_a'])
        },
        examples_coverage: { 'ex_a' => { original_path => [1] } },
        boot_set: {},
        wsi_snapshot: {},
        env_snapshot: {},
        env_dependency: {}
      )
    end

    shared_examples 'preserves hardlink siblings as distinct all_files keys' do
      it 'round-trips both paths as separate all_files entries (storage layer is opaque)' do
        snap = backend.load_graph(schema_version: schema_version)

        expect(snap.all_files).to have_key(original_path)
        expect(snap.all_files).to have_key(hardlink_path)
        expect(snap.all_files.size).to eq(2)
      end

      it 'round-trips identical digests on both paths' do
        snap = backend.load_graph(schema_version: schema_version)

        expect(snap.all_files[original_path][:digest]).to eq(snap.all_files[hardlink_path][:digest])
      end

      it 'round-trips the dependency relation pointing at both paths' do
        snap = backend.load_graph(schema_version: schema_version)

        expect(snap.dependency.fetch('ex_a')).to contain_exactly(original_path, hardlink_path)
      end
    end

    describe 'JsonBackend :json' do
      let(:backend) { RSpecTracer::Storage::JsonBackend.new(cache_path: cache_path, serializer: :json) }

      before { backend.save_graph(build_hardlink_snapshot('run-hardlink-json'), schema_version: schema_version) }

      it_behaves_like 'preserves hardlink siblings as distinct all_files keys'
    end

    describe 'JsonBackend :msgpack' do
      let(:backend) { RSpecTracer::Storage::JsonBackend.new(cache_path: cache_path, serializer: :msgpack) }

      before { backend.save_graph(build_hardlink_snapshot('run-hardlink-msgpack'), schema_version: schema_version) }

      it_behaves_like 'preserves hardlink siblings as distinct all_files keys'
    end

    describe 'SqliteBackend' do
      before do
        sqlite_available =
          begin
            require 'sqlite3'
            require 'rspec_tracer/storage/sqlite_backend'
            RUBY_ENGINE == 'ruby'
          rescue LoadError
            false
          end
        skip 'sqlite3 gem not installable on this Ruby (JRuby or missing dep)' unless sqlite_available
        backend.save_graph(build_hardlink_snapshot('run-hardlink-sqlite'), schema_version: schema_version)
      end

      let(:backend) { RSpecTracer::Storage::SqliteBackend.new(cache_path: cache_path) }

      it_behaves_like 'preserves hardlink siblings as distinct all_files keys'
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleMemoizedHelpers
