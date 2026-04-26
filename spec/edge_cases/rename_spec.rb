# frozen_string_literal: true

# File renamed between runs. Cold run carries `old_name.rb` in
# all_files; warm run discovers `new_name.rb` and the old key is
# absent. The storage layer's full-replace save_graph contract
# guarantees the warm snapshot completely supersedes the cold one
# - no merge, no stale all_files keys leaking forward.
#
# Tracker-level "rename detection" (correlating old_name +
# new_name as the same logical file) is out of scope for storage:
# storage treats the path as opaque, so a rename looks identical
# to "old file deleted + new file added." Higher layers can layer
# rename heuristics on top if they want.

require 'fileutils'
require 'set'
require 'tmpdir'
require 'rspec_tracer/storage/json_backend'
require 'rspec_tracer/storage/snapshot'

# rubocop:disable RSpec/DescribeClass, RSpec/MultipleMemoizedHelpers
RSpec.describe 'File rename between runs' do
  let(:tmp_base) { Dir.mktmpdir('rspec_tracer_rename_') }
  let(:cache_path) { File.join(tmp_base, 'cache') }
  let(:schema_version) { RSpecTracer::Storage::Schema::CURRENT }
  let(:old_path) { '/spec/old_name_spec.rb' }
  let(:new_path) { '/spec/new_name_spec.rb' }

  after { FileUtils.rm_rf(tmp_base) if tmp_base }

  def build_snapshot(run_id, file_path, marker)
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
      all_files: { file_path => { file_name: file_path, file_path: file_path, digest: 'abc' } },
      dependency: { marker => Set.new([file_path]) },
      reverse_dependency: { file_path => Set.new([marker]) },
      examples_coverage: { marker => { file_path => [1] } },
      boot_set: {},
      wsi_snapshot: {},
      env_snapshot: {},
      env_dependency: {}
    )
  end

  describe 'filesystem behavior under File.rename' do
    it 'preserves file contents through a rename' do
      original = File.join(tmp_base, 'before.rb')
      renamed = File.join(tmp_base, 'after.rb')
      File.write(original, "x = 1\n")

      File.rename(original, renamed)

      expect(File).not_to exist(original)
      expect(File.read(renamed)).to eq("x = 1\n")
    end
  end

  shared_examples 'replaces the cold all_files entry on the warm save' do
    it 'reads back only the warm path, not the cold one' do
      backend.save_graph(build_snapshot('run-cold', old_path, 'ex_a'), schema_version: schema_version)
      backend.save_graph(build_snapshot('run-warm', new_path, 'ex_a'), schema_version: schema_version)

      snap = backend.load_graph(schema_version: schema_version)

      expect(snap.run_id).to eq('run-warm')
      expect(snap.all_files).to have_key(new_path)
      expect(snap.all_files).not_to have_key(old_path)
    end

    it 'replaces the dependency edges across the rename' do
      backend.save_graph(build_snapshot('run-cold', old_path, 'ex_a'), schema_version: schema_version)
      backend.save_graph(build_snapshot('run-warm', new_path, 'ex_a'), schema_version: schema_version)

      snap = backend.load_graph(schema_version: schema_version)

      expect(snap.dependency.fetch('ex_a')).to contain_exactly(new_path)
      expect(snap.reverse_dependency).to have_key(new_path)
      expect(snap.reverse_dependency).not_to have_key(old_path)
    end
  end

  describe 'JsonBackend :json' do
    let(:backend) { RSpecTracer::Storage::JsonBackend.new(cache_path: cache_path, serializer: :json) }

    it_behaves_like 'replaces the cold all_files entry on the warm save'
  end

  describe 'JsonBackend :msgpack' do
    let(:backend) { RSpecTracer::Storage::JsonBackend.new(cache_path: cache_path, serializer: :msgpack) }

    it_behaves_like 'replaces the cold all_files entry on the warm save'
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
    end

    let(:backend) { RSpecTracer::Storage::SqliteBackend.new(cache_path: cache_path) }

    it_behaves_like 'replaces the cold all_files entry on the warm save'
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleMemoizedHelpers
