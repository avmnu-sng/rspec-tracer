# frozen_string_literal: true

# Disk-full / mid-write failure recovery. A failing save_graph must
# not poison the cache: the previous successful run stays loadable,
# a subsequent save (after disk space recovers) succeeds, and
# orphaned partial state never surfaces as a corrupted snapshot to
# load_graph.
#
# JsonBackend recovery contract:
#   - transactional_save's flock-protected block raises the
#     underlying Errno::ENOSPC up to the caller. last_run.json is
#     written LAST via tmp+rename, so a failure during write_run_files
#     leaves last_run.json still pointing at the prior valid run.
#   - Half-written .tmp files in the failed run-id directory are
#     orphaned but harmless - load_graph sees the prior run-id
#     manifest and ignores anything else under cache_path.
#
# SqliteBackend recovery contract:
#   - BEGIN IMMEDIATE wraps the entire save_graph write set. A mid-
#     transaction error triggers SQLite's automatic rollback - the
#     prior run's rows survive intact.

require 'fileutils'
require 'json'
require 'set'
require 'tmpdir'
require 'rspec_tracer/storage/json_backend'
require 'rspec_tracer/storage/snapshot'

PARTIAL_FAILURE_SQLITE_AVAILABLE =
  begin
    require 'sqlite3'
    require 'rspec_tracer/storage/sqlite_backend'
    RUBY_ENGINE == 'ruby'
  rescue LoadError
    false
  end

# rubocop:disable RSpec/DescribeClass
RSpec.describe 'Partial failure — mid-write disk-full recovery' do
  let(:tmp_base) { Dir.mktmpdir('rspec_tracer_partial_failure_') }
  let(:cache_path) { File.join(tmp_base, 'cache') }
  let(:schema_version) { RSpecTracer::Storage::Schema::CURRENT }

  after { FileUtils.rm_rf(tmp_base) if tmp_base }

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
    end

    it 'preserves the prior run when File.binwrite raises ENOSPC mid-stream' do
      original = File.method(:binwrite)
      call_count = 0
      allow(File).to receive(:binwrite) do |path, *rest|
        call_count += 1
        raise Errno::ENOSPC, 'no space left on device' if call_count == 5

        original.call(path, *rest)
      end

      expect do
        backend.save_graph(build_snapshot('beta', 'ex_b'), schema_version: schema_version)
      end.to raise_error(Errno::ENOSPC)

      # last_run.json still points at alpha (last step never executed).
      reader = RSpecTracer::Storage::JsonBackend.new(cache_path: cache_path)
      snap = reader.load_graph(schema_version: schema_version)
      expect(snap).not_to be_nil
      expect(snap.run_id).to eq('alpha')
      expect(snap.all_examples).to have_key('ex_a')
    end

    it 'preserves the prior run when File.rename raises ENOSPC on the manifest commit' do
      original = File.method(:rename)
      allow(File).to receive(:rename) do |src, dst|
        raise Errno::ENOSPC, 'no space left on device' if dst.end_with?('last_run.json')

        original.call(src, dst)
      end

      expect do
        backend.save_graph(build_snapshot('beta', 'ex_b'), schema_version: schema_version)
      end.to raise_error(Errno::ENOSPC)

      reader = RSpecTracer::Storage::JsonBackend.new(cache_path: cache_path)
      snap = reader.load_graph(schema_version: schema_version)
      expect(snap.run_id).to eq('alpha')
    end

    it 'allows a subsequent save to succeed after the disk-full condition clears' do
      raised = false
      original = File.method(:binwrite)
      # write_payload_atomic writes to a `.tmp.<pid>.<rand>` path
      # before renaming, so the binwrite path includes the final
      # filename as a substring rather than ending with it.
      allow(File).to receive(:binwrite) do |path, *rest|
        if !raised && path.include?('all_examples.json')
          raised = true
          raise Errno::ENOSPC, 'no space left on device'
        end

        original.call(path, *rest)
      end

      expect { backend.save_graph(build_snapshot('beta', 'ex_b'), schema_version: schema_version) }
        .to raise_error(Errno::ENOSPC)
      RSpec::Mocks.space.proxy_for(File).reset
      backend.save_graph(build_snapshot('gamma', 'ex_c'), schema_version: schema_version)

      reader = RSpecTracer::Storage::JsonBackend.new(cache_path: cache_path)
      snap = reader.load_graph(schema_version: schema_version)
      expect(snap.run_id).to eq('gamma')
      expect(snap.all_examples.keys).to eq(['ex_c'])
    end

    it 'leaves orphaned tmp files harmless - load_graph ignores them' do
      original = File.method(:rename)
      allow(File).to receive(:rename) do |src, dst|
        raise Errno::ENOSPC, 'no space left on device' if dst.end_with?('all_examples.json')

        original.call(src, dst)
      end

      expect { backend.save_graph(build_snapshot('beta', 'ex_b'), schema_version: schema_version) }
        .to raise_error(Errno::ENOSPC)

      # A tmp file may exist under the beta run-id dir.
      tmps = Dir[File.join(cache_path, 'beta', '*.tmp.*')]
      # We don't assert tmps are present (the rescue in write_payload_atomic
      # cleans them up); we assert that whether or not they linger, the
      # reader is unfazed.
      reader = RSpecTracer::Storage::JsonBackend.new(cache_path: cache_path)
      expect { reader.load_graph(schema_version: schema_version) }.not_to raise_error
      expect(reader.load_graph(schema_version: schema_version).run_id).to eq('alpha')
      expect(tmps).to all(satisfy { |p| File.file?(p) || !File.exist?(p) }) # informational
    end
  end

  describe 'SqliteBackend' do
    before do
      skip 'sqlite3 gem not installable on this Ruby (JRuby or missing dep)' unless PARTIAL_FAILURE_SQLITE_AVAILABLE
      backend.save_graph(build_snapshot('alpha', 'ex_a'), schema_version: schema_version)
    end

    let(:backend) { RSpecTracer::Storage::SqliteBackend.new(cache_path: cache_path) }

    it 'rolls back the in-flight transaction when an INSERT fails mid-stream' do
      raise_after = 5
      call_count = 0
      original_execute = SQLite3::Database.instance_method(:execute)
      # rubocop:disable RSpec/AnyInstance
      allow_any_instance_of(SQLite3::Database).to receive(:execute) do |db, sql, *rest|
        call_count += 1
        if sql.start_with?('INSERT') && call_count > raise_after
          raise SQLite3::Exception, 'simulated mid-transaction failure'
        end

        original_execute.bind_call(db, sql, *rest)
      end
      # rubocop:enable RSpec/AnyInstance

      expect do
        backend.save_graph(build_snapshot('beta', 'ex_b'), schema_version: schema_version)
      end.to raise_error(SQLite3::Exception, /simulated/)

      RSpec::Mocks.space.proxy_for(SQLite3::Database).reset
      reader = RSpecTracer::Storage::SqliteBackend.new(cache_path: cache_path)
      snap = reader.load_graph(schema_version: schema_version)

      expect(snap).not_to be_nil
      expect(snap.run_id).to eq('alpha'), 'BEGIN IMMEDIATE rollback should preserve the prior run'
    end

    it 'allows a subsequent save to succeed after the failed save rolls back' do
      raised = false
      original_execute = SQLite3::Database.instance_method(:execute)
      # rubocop:disable RSpec/AnyInstance
      allow_any_instance_of(SQLite3::Database).to receive(:execute) do |db, sql, *rest|
        if !raised && sql.include?('INSERT INTO examples')
          raised = true
          raise SQLite3::Exception, 'simulated mid-transaction failure'
        end

        original_execute.bind_call(db, sql, *rest)
      end
      # rubocop:enable RSpec/AnyInstance

      expect { backend.save_graph(build_snapshot('beta', 'ex_b'), schema_version: schema_version) }
        .to raise_error(SQLite3::Exception)

      RSpec::Mocks.space.proxy_for(SQLite3::Database).reset
      backend.save_graph(build_snapshot('gamma', 'ex_c'), schema_version: schema_version)

      reader = RSpecTracer::Storage::SqliteBackend.new(cache_path: cache_path)
      snap = reader.load_graph(schema_version: schema_version)
      expect(snap.run_id).to eq('gamma')
    end
  end
end
# rubocop:enable RSpec/DescribeClass
