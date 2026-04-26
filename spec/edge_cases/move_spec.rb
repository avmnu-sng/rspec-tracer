# frozen_string_literal: true

# File moved across directories. Cold run sees `/old/dir/foo.rb`;
# warm run sees `/new/dir/foo.rb`. Same opaque-key contract as
# rename_spec.rb - the storage layer treats this as "old path
# absent + new path present", and tracker-level move detection
# (matching by basename + content digest) is out of scope.
#
# This file complements rename_spec.rb: rename keeps the
# basename, move keeps the basename but changes the dir. Both
# round-trip through the storage layer identically; the spec is
# present so a future regression that special-cases one pattern
# but not the other is caught.

require 'fileutils'
require 'set'
require 'tmpdir'
require 'rspec_tracer/storage/json_backend'
require 'rspec_tracer/storage/snapshot'

# rubocop:disable RSpec/DescribeClass, RSpec/MultipleMemoizedHelpers
RSpec.describe 'File moved across directories between runs' do
  let(:tmp_base) { Dir.mktmpdir('rspec_tracer_move_') }
  let(:cache_path) { File.join(tmp_base, 'cache') }
  let(:schema_version) { RSpecTracer::Storage::Schema::CURRENT }
  let(:old_path) { '/spec/legacy/feature_spec.rb' }
  let(:new_path) { '/spec/integration/feature_spec.rb' }

  after { FileUtils.rm_rf(tmp_base) if tmp_base }

  def build_snapshot(run_id, file_path, marker)
    RSpecTracer::Storage::Snapshot.new(
      schema_version: RSpecTracer::Storage::Schema::CURRENT,
      run_id: run_id,
      all_examples: { marker => { id: marker, description: "from #{marker}", file_path: file_path } },
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

  describe 'filesystem behavior under File.rename across dirs' do
    it 'moves a file across directories preserving content' do
      old_dir = File.join(tmp_base, 'old')
      new_dir = File.join(tmp_base, 'new')
      FileUtils.mkdir_p(old_dir)
      FileUtils.mkdir_p(new_dir)
      original = File.join(old_dir, 'feature_spec.rb')
      moved = File.join(new_dir, 'feature_spec.rb')
      File.write(original, "describe 'X' do\n  it 'works' do; end\nend\n")

      File.rename(original, moved)

      expect(File).not_to exist(original)
      expect(File.read(moved)).to include('describe')
    end
  end

  shared_examples 'replaces the cold path with the moved-to path on warm save' do
    it 'reads back only the new directory path' do
      backend.save_graph(build_snapshot('run-cold', old_path, 'ex_a'), schema_version: schema_version)
      backend.save_graph(build_snapshot('run-warm', new_path, 'ex_a'), schema_version: schema_version)

      snap = backend.load_graph(schema_version: schema_version)

      expect(snap.run_id).to eq('run-warm')
      expect(snap.all_files).to have_key(new_path)
      expect(snap.all_files).not_to have_key(old_path)
    end

    it 'replaces the dependency + examples_coverage edges across the move' do
      backend.save_graph(build_snapshot('run-cold', old_path, 'ex_a'), schema_version: schema_version)
      backend.save_graph(build_snapshot('run-warm', new_path, 'ex_a'), schema_version: schema_version)

      snap = backend.load_graph(schema_version: schema_version)

      expect(snap.dependency.fetch('ex_a')).to contain_exactly(new_path)
      expect(snap.examples_coverage.fetch('ex_a')).to have_key(new_path)
      expect(snap.examples_coverage.fetch('ex_a')).not_to have_key(old_path)
    end
  end

  describe 'JsonBackend :json' do
    let(:backend) { RSpecTracer::Storage::JsonBackend.new(cache_path: cache_path, serializer: :json) }

    it_behaves_like 'replaces the cold path with the moved-to path on warm save'
  end

  describe 'JsonBackend :msgpack' do
    let(:backend) { RSpecTracer::Storage::JsonBackend.new(cache_path: cache_path, serializer: :msgpack) }

    it_behaves_like 'replaces the cold path with the moved-to path on warm save'
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

    it_behaves_like 'replaces the cold path with the moved-to path on warm save'
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleMemoizedHelpers
