# frozen_string_literal: true

# Symlinks in the dependency graph: a file referenced via a symlink
# path is a distinct entry in all_files / dependency from its
# resolved target. The storage layer treats path strings as opaque
# keys; resolution semantics live in Tracker::CoverageAdapter
# (M3.1) and Tracker::DependencyGraph (M3.5). This spec asserts:
#
#   - Storage round-trip preserves symlink + target as two distinct
#     all_files keys (the tracker's choice of which to record is
#     not the storage's concern).
#   - File.symlink + Digest::SHA256.file follows the link by default,
#     so both paths in all_files would have the same `digest`
#     value when both are explicitly observed.
#   - A broken symlink (target missing) round-trips with whatever
#     digest the caller chose to record (nil from
#     CoverageAdapter#file_digest's SystemCallError rescue path
#     when the target is missing).
#
# Symlink support: Linux + macOS yes; Windows yes only with admin
# (we don't support Windows). Skip on Windows.

return if Gem.win_platform?

require 'digest'
require 'fileutils'
require 'set'
require 'tmpdir'
require 'rspec_tracer/storage/json_backend'
require 'rspec_tracer/storage/snapshot'

# rubocop:disable RSpec/DescribeClass, RSpec/MultipleMemoizedHelpers
RSpec.describe 'Symlinks in cache content + filesystem semantics' do
  let(:tmp_base) { Dir.mktmpdir('rspec_tracer_symlink_') }
  let(:cache_path) { File.join(tmp_base, 'cache') }
  let(:schema_version) { RSpecTracer::Storage::Schema::CURRENT }

  after { FileUtils.rm_rf(tmp_base) if tmp_base }

  describe 'filesystem behavior under Digest::SHA256.file' do
    it 'follows the symlink and returns the target file digest' do
      target = File.join(tmp_base, 'target.rb')
      link = File.join(tmp_base, 'link.rb')
      File.write(target, "puts 'hello'\n")
      File.symlink(target, link)

      target_digest = Digest::SHA256.file(target).hexdigest
      link_digest = Digest::SHA256.file(link).hexdigest

      expect(link_digest).to eq(target_digest)
    end

    it 'raises Errno::ENOENT on a broken symlink (target missing)' do
      missing = File.join(tmp_base, 'nope.rb')
      link = File.join(tmp_base, 'broken.rb')
      File.symlink(missing, link)

      expect { Digest::SHA256.file(link) }.to raise_error(Errno::ENOENT)
    end
  end

  describe 'storage round-trip' do
    let(:target_path) { '/spec/target.rb' }
    let(:link_path) { '/spec/link.rb' }

    def build_symlink_snapshot(run_id)
      RSpecTracer::Storage::Snapshot.new(
        schema_version: RSpecTracer::Storage::Schema::CURRENT,
        run_id: run_id,
        all_examples: { 'ex_a' => { id: 'ex_a', description: 'uses both target + link' } },
        duplicate_examples: {},
        interrupted_examples: Set.new,
        flaky_examples: Set.new,
        failed_examples: Set.new,
        pending_examples: Set.new,
        skipped_examples: Set.new,
        all_files: {
          target_path => { file_name: target_path, file_path: target_path, digest: 'shared_digest' },
          link_path => { file_name: link_path, file_path: link_path, digest: 'shared_digest' }
        },
        dependency: { 'ex_a' => Set.new([target_path, link_path]) },
        reverse_dependency: {
          target_path => Set.new(['ex_a']),
          link_path => Set.new(['ex_a'])
        },
        examples_coverage: { 'ex_a' => { target_path => [1] } },
        boot_set: {},
        wsi_snapshot: {},
        env_snapshot: {},
        env_dependency: {}
      )
    end

    shared_examples 'preserves symlink + target as distinct all_files keys' do
      it 'round-trips both paths as separate all_files entries' do
        snap = backend.load_graph(schema_version: schema_version)

        expect(snap.all_files).to have_key(target_path)
        expect(snap.all_files).to have_key(link_path)
        expect(snap.all_files.size).to eq(2)
      end

      it 'round-trips the dependency relation pointing at both paths' do
        snap = backend.load_graph(schema_version: schema_version)

        expect(snap.dependency.fetch('ex_a')).to contain_exactly(target_path, link_path)
      end

      it 'round-trips identical digests for both paths' do
        snap = backend.load_graph(schema_version: schema_version)

        expect(snap.all_files[target_path][:digest]).to eq(snap.all_files[link_path][:digest])
      end
    end

    describe 'JsonBackend :json' do
      let(:backend) { RSpecTracer::Storage::JsonBackend.new(cache_path: cache_path, serializer: :json) }

      before { backend.save_graph(build_symlink_snapshot('run-symlink-json'), schema_version: schema_version) }

      it_behaves_like 'preserves symlink + target as distinct all_files keys'
    end

    describe 'JsonBackend :msgpack' do
      let(:backend) { RSpecTracer::Storage::JsonBackend.new(cache_path: cache_path, serializer: :msgpack) }

      before { backend.save_graph(build_symlink_snapshot('run-symlink-msgpack'), schema_version: schema_version) }

      it_behaves_like 'preserves symlink + target as distinct all_files keys'
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
        backend.save_graph(build_symlink_snapshot('run-symlink-sqlite'), schema_version: schema_version)
      end

      let(:backend) { RSpecTracer::Storage::SqliteBackend.new(cache_path: cache_path) }

      it_behaves_like 'preserves symlink + target as distinct all_files keys'
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleMemoizedHelpers
