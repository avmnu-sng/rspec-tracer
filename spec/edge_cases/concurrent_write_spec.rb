# frozen_string_literal: true

# Two concurrent processes writing the same cache: last-writer-wins,
# no corruption, no leftover .tmp files. The storage backends'
# write-side locking contracts must serialize concurrent save_graph
# calls without dropping bytes or wedging either writer.
#
#   - JsonBackend: exclusive flock on `.rspec_tracer.lock` blocks
#     the second writer until the first finishes the
#     transactional_save. Default flock semantics block, so this is
#     naturally robust.
#   - SqliteBackend: `BEGIN IMMEDIATE` acquires SQLite's RESERVED
#     write lock. Without a busy_timeout configured, the second
#     `BEGIN IMMEDIATE` returns SQLITE_BUSY immediately. The fix
#     belongs in SqliteBackend's configure_connection (added in
#     M8.2 alongside this spec).
#
# Children exit via `Process.exit!(0)` to bypass SimpleCov's
# per-process at_exit hook (memory:
# `feedback_simplecov_fork_poisoning`). Without the bang, the child
# rewrites the parent's coverage snapshot with its narrow slice and
# drops effective coverage below the gate.
#
# fork() is MRI-only. Skip the entire spec on JRuby - threaded test
# runners are out of scope for the storage layer's flock-based model
# (storage is single-threaded by design; concurrency comes from
# parallel_tests at the process level).

return unless Process.respond_to?(:fork)

require 'fileutils'
require 'set'
require 'tmpdir'
require 'rspec_tracer/storage/json_backend'
require 'rspec_tracer/storage/snapshot'

CONCURRENT_WRITE_SQLITE_AVAILABLE =
  begin
    require 'sqlite3'
    require 'rspec_tracer/storage/sqlite_backend'
    RUBY_ENGINE == 'ruby'
  rescue LoadError
    false
  end

# rubocop:disable RSpec/DescribeClass
RSpec.describe 'Concurrent writers — last-writer-wins under lock contention' do
  let(:tmp_base) { Dir.mktmpdir('rspec_tracer_concurrent_') }
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

  # Synchronize two children to release simultaneously. Each child
  # blocks on its own pipe; parent writes "g" to both pipes after the
  # forks complete so both writers race for the lock at roughly the
  # same instant. Returns [exit_status_a, exit_status_b].
  def race_two_writers(make_a, make_b)
    read_a, write_a = IO.pipe
    read_b, write_b = IO.pipe

    pid_a = fork do
      write_a.close
      read_a.read(1)
      run_child(&make_a)
    end

    pid_b = fork do
      write_b.close
      read_b.read(1)
      run_child(&make_b)
    end

    read_a.close
    read_b.close
    write_a.write('g')
    write_b.write('g')
    write_a.close
    write_b.close

    _, status_a = Process.waitpid2(pid_a)
    _, status_b = Process.waitpid2(pid_b)
    [status_a.exitstatus, status_b.exitstatus]
  end

  # Run a child's save_graph block, capturing any StandardError and
  # exiting via Process.exit! (skipping SimpleCov's at_exit hook).
  # Children inherit the parent's loaded RSpec/SimpleCov state via
  # fork's copy-on-write; bypass the per-process result writer or
  # the parent's coverage snapshot gets stomped.
  def run_child
    yield
    Process.exit!(0)
  rescue StandardError => e
    warn "child #{Process.pid} failed: #{e.class}: #{e.message}"
    Process.exit!(1)
  end

  describe 'JsonBackend two concurrent save_graph calls' do
    it 'persists one writer\'s snapshot via the flock-serialized transaction' do
      FileUtils.mkdir_p(cache_path)

      make_a = -> { RSpecTracer::Storage::JsonBackend.new(cache_path: cache_path).save_graph(build_snapshot('alpha', 'ex_a'), schema_version: schema_version) }
      make_b = -> { RSpecTracer::Storage::JsonBackend.new(cache_path: cache_path).save_graph(build_snapshot('beta', 'ex_b'), schema_version: schema_version) }
      status_a, status_b = race_two_writers(make_a, make_b)

      expect(status_a).to eq(0), "child A failed (exit #{status_a})"
      expect(status_b).to eq(0), "child B failed (exit #{status_b})"

      reader = RSpecTracer::Storage::JsonBackend.new(cache_path: cache_path)
      snap = reader.load_graph(schema_version: schema_version)

      expect(snap).not_to be_nil
      expect(snap.run_id).to eq('alpha').or eq('beta')

      # Every per-run file present in the winning run-id dir.
      run_dir = File.join(cache_path, snap.run_id)
      RSpecTracer::Storage::JsonBackend::FILENAMES.each do |filename|
        expect(File).to exist(File.join(run_dir, filename)), "missing #{filename} in winning run-id dir #{snap.run_id}"
      end

      # Atomic rename succeeded - no orphaned tmp files.
      tmps = Dir[File.join(cache_path, '**', '*.tmp.*')]
      expect(tmps).to be_empty, "leftover tmp files: #{tmps.inspect}"

      # Lock file persists by design (flock semantics; the file is
      # the lock-state holder, not deleted on release).
      expect(File.exist?(File.join(cache_path, RSpecTracer::Storage::JsonBackend::LOCK_FILENAME))).to be(true)
    end

    it 'leaves the cache loadable by a third reader after the race resolves' do
      FileUtils.mkdir_p(cache_path)

      make_a = -> { RSpecTracer::Storage::JsonBackend.new(cache_path: cache_path).save_graph(build_snapshot('alpha', 'ex_a'), schema_version: schema_version) }
      make_b = -> { RSpecTracer::Storage::JsonBackend.new(cache_path: cache_path).save_graph(build_snapshot('beta', 'ex_b'), schema_version: schema_version) }
      race_two_writers(make_a, make_b)

      reader = RSpecTracer::Storage::JsonBackend.new(cache_path: cache_path)
      snap = reader.load_graph(schema_version: schema_version)

      expect(snap.all_examples.keys).to eq(['ex_a']).or eq(['ex_b'])
    end
  end

  describe 'SqliteBackend two concurrent save_graph calls' do
    before do
      skip 'sqlite3 gem not installable on this Ruby (JRuby or missing dep)' unless CONCURRENT_WRITE_SQLITE_AVAILABLE
    end

    it 'persists one writer\'s snapshot via BEGIN IMMEDIATE + busy_timeout' do
      FileUtils.mkdir_p(cache_path)

      make_a = -> { RSpecTracer::Storage::SqliteBackend.new(cache_path: cache_path).save_graph(build_snapshot('alpha', 'ex_a'), schema_version: schema_version) }
      make_b = -> { RSpecTracer::Storage::SqliteBackend.new(cache_path: cache_path).save_graph(build_snapshot('beta', 'ex_b'), schema_version: schema_version) }
      status_a, status_b = race_two_writers(make_a, make_b)

      expect(status_a).to eq(0), "child A failed (exit #{status_a}) — busy_timeout missing or too short?"
      expect(status_b).to eq(0), "child B failed (exit #{status_b}) — busy_timeout missing or too short?"

      reader = RSpecTracer::Storage::SqliteBackend.new(cache_path: cache_path)
      snap = reader.load_graph(schema_version: schema_version)

      expect(snap).not_to be_nil
      expect(snap.run_id).to eq('alpha').or eq('beta')

      # Single .sqlite3 file; no WAL/SHM sidecars (journal_mode=MEMORY).
      sidecars = Dir[File.join(cache_path, '*.sqlite3-wal')] + Dir[File.join(cache_path, '*.sqlite3-shm')]
      expect(sidecars).to be_empty, "leftover SQLite sidecars: #{sidecars.inspect}"
    end
  end
end
# rubocop:enable RSpec/DescribeClass
