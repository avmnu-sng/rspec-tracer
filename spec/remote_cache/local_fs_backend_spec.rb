# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'tmpdir'

require 'rspec_tracer/remote_cache/local_fs_backend'
require 'rspec_tracer/storage/schema'
require_relative '../contracts/remote_cache_backend'

# rubocop:disable RSpec/InstanceVariable, RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe RSpecTracer::RemoteCache::LocalFsBackend do
  around do |example|
    Dir.mktmpdir('rspec-tracer-local-cache-') do |cache|
      Dir.mktmpdir('rspec-tracer-local-root-') do |root|
        @cache_path = cache
        @root = root
        example.run
      end
    end
  end

  let(:current_schema) { RSpecTracer::Storage::Schema::CURRENT }

  def new_backend(branch: 'main', default_branch: 'main', test_suite_id: nil, root: nil)
    described_class.new(
      root: root || @root,
      branch: branch,
      default_branch: default_branch,
      test_suite_id: test_suite_id,
      cache_path: @cache_path
    )
  end

  def write_local_cache(run_id: 'abc123', schema: current_schema)
    File.write(
      File.join(@cache_path, 'last_run.json'),
      JSON.pretty_generate('schema_version' => schema, 'run_id' => run_id)
    )
    FileUtils.mkdir_p(File.join(@cache_path, run_id))
    File.write(File.join(@cache_path, run_id, 'all_examples.json'), '{"ex1":"passed"}')
    File.write(File.join(@cache_path, run_id, 'dependency.json'), '{"ex1":["lib/foo.rb"]}')
  end

  it_behaves_like 'a RemoteCache::Backend' do
    let(:backend) { new_backend }
  end

  describe '#initialize' do
    it 'raises on missing root' do
      expect do
        described_class.new(root: nil, branch: 'main', default_branch: 'main', cache_path: @cache_path)
      end.to raise_error(described_class::LocalFsBackendError, /root/)
    end

    it 'raises on empty root' do
      expect do
        described_class.new(root: '', branch: 'main', default_branch: 'main', cache_path: @cache_path)
      end.to raise_error(described_class::LocalFsBackendError, /root/)
    end

    it 'raises on missing branch' do
      expect do
        described_class.new(root: @root, branch: nil, default_branch: 'main', cache_path: @cache_path)
      end.to raise_error(described_class::LocalFsBackendError, /branch/)
    end

    it 'raises on missing default_branch' do
      expect do
        described_class.new(root: @root, branch: 'main', default_branch: nil, cache_path: @cache_path)
      end.to raise_error(described_class::LocalFsBackendError, /default_branch/)
    end

    it 'raises on missing cache_path' do
      expect do
        described_class.new(root: @root, branch: 'main', default_branch: 'main', cache_path: nil)
      end.to raise_error(described_class::LocalFsBackendError, /cache_path/)
    end

    it 'expands a relative root to absolute' do
      Dir.chdir(Dir.tmpdir) do
        backend = described_class.new(root: '.', branch: 'main', default_branch: 'main', cache_path: @cache_path)
        internal_root = backend.instance_variable_get(:@root)
        expect(File.absolute_path?(internal_root)).to be(true)
      end
    end

    it 'accepts an empty test_suite_id and normalizes to nil' do
      backend = described_class.new(root: @root, branch: 'main', default_branch: 'main',
                                    cache_path: @cache_path, test_suite_id: '')
      expect(backend.instance_variable_get(:@test_suite_id)).to be_nil
    end
  end

  describe '#download' do
    it 'returns false for nil ref' do
      expect(new_backend.download(nil)).to be(false)
    end

    it 'returns false for empty ref' do
      expect(new_backend.download('')).to be(false)
    end

    it 'returns false when no archive exists at the expected path' do
      expect(new_backend.download('missing-sha')).to be(false)
    end

    it 'round-trips a valid archive on main tier' do
      backend = new_backend
      write_local_cache(run_id: 'run-main')
      backend.upload('sha1')

      FileUtils.rm_rf(Dir.glob(File.join(@cache_path, '*')))

      expect(backend.download('sha1')).to be(true)
      expect(File.exist?(File.join(@cache_path, 'last_run.json'))).to be(true)
      expect(File.exist?(File.join(@cache_path, 'run-main', 'all_examples.json'))).to be(true)
    end

    it 'falls back to main tier from a pr backend when pr tier has no archive' do
      main = new_backend(branch: 'main', default_branch: 'main')
      write_local_cache(run_id: 'run-shared')
      main.upload('shared-sha')

      FileUtils.rm_rf(Dir.glob(File.join(@cache_path, '*')))
      pr = new_backend(branch: 'feat', default_branch: 'main')

      expect(pr.download('shared-sha')).to be(true)
    end

    it 'rejects an archive with a mismatched schema_version' do
      backend = new_backend
      write_local_cache(run_id: 'run-bad-schema', schema: current_schema + 99)
      backend.upload('bad-sha')

      FileUtils.rm_rf(Dir.glob(File.join(@cache_path, '*')))

      expect(backend.download('bad-sha')).to be(false)
      expect(File.exist?(File.join(@cache_path, 'last_run.json'))).to be(false)
    end

    it 'rolls back on a malformed archive without leaving partial files' do
      backend = new_backend
      dest = File.join(@root, 'main', 'corrupt-sha', 'cache.tar.gz')
      FileUtils.mkdir_p(File.dirname(dest))
      File.write(dest, 'not-a-gzip')

      expect(backend.download('corrupt-sha')).to be(false)
      expect(Dir.children(@cache_path)).to be_empty
    end

    it 'scopes the archive under a test_suite_id subdirectory when set' do
      backend = new_backend(test_suite_id: '3')
      write_local_cache(run_id: 'run-suite-3')
      backend.upload('sha-s')

      archive = File.join(@root, 'main', 'sha-s', '3', 'cache.tar.gz')
      expect(File.file?(archive)).to be(true)
    end
  end

  describe '#upload' do
    it 'raises on empty ref' do
      expect { new_backend.upload('') }.to raise_error(described_class::LocalFsBackendError, /ref is required/)
    end

    it 'raises when no local cache to upload' do
      expect { new_backend.upload('sha1') }.to raise_error(described_class::LocalFsBackendError, /no local cache/)
    end

    it 'raises when last_run.json is malformed JSON (treats as missing cache)' do
      File.write(File.join(@cache_path, 'last_run.json'), '{not json')

      expect { new_backend.upload('sha1') }.to raise_error(described_class::LocalFsBackendError, /no local cache/)
    end

    it 'places the archive at the expected pr-tier path' do
      backend = new_backend(branch: 'feat', default_branch: 'main')
      write_local_cache(run_id: 'run-pr')
      backend.upload('feat-sha')

      archive = File.join(@root, 'pr', 'feat', 'feat-sha', 'cache.tar.gz')
      expect(File.file?(archive)).to be(true)
    end

    it 'cleans up the staging file if rename fails' do
      backend = new_backend
      write_local_cache(run_id: 'run-failrename')
      allow(File).to receive(:rename).and_raise(Errno::ENOSPC)

      expect { backend.upload('fail-sha') }.to raise_error(Errno::ENOSPC)
      # Staging files use .tmp.<pid>. suffix; none should remain.
      dir = File.join(@root, 'main', 'fail-sha')
      leftover = Dir.exist?(dir) ? Dir.children(dir).grep(/\.tmp\./) : []
      expect(leftover).to be_empty
    end
  end

  describe '#branch_refs' do
    it 'returns {} for a nonexistent branch' do
      expect(new_backend(branch: 'feat', default_branch: 'main').branch_refs('feat')).to eq({})
    end

    it 'writes and reads branch_refs atomically' do
      backend = new_backend(branch: 'feat', default_branch: 'main')
      refs = { 'sha1' => 1_700_000_000, 'sha2' => 1_700_000_100 }

      backend.write_branch_refs('feat', refs)

      path = File.join(@root, 'pr', 'feat', 'branch_refs.json')
      expect(File.file?(path)).to be(true)
      expect(backend.branch_refs('feat')).to eq(refs)
    end

    it 'returns {} when the file contains non-Hash JSON' do
      backend = new_backend(branch: 'feat', default_branch: 'main')
      path = File.join(@root, 'pr', 'feat', 'branch_refs.json')
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, '"not a hash"')

      expect(backend.branch_refs('feat')).to eq({})
    end

    it 'returns {} when the file is malformed JSON' do
      backend = new_backend(branch: 'feat', default_branch: 'main')
      path = File.join(@root, 'pr', 'feat', 'branch_refs.json')
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, '{not json')

      expect(backend.branch_refs('feat')).to eq({})
    end
  end

  describe '#write_branch_refs' do
    it 'is a no-op for main-branch writes' do
      backend = new_backend(branch: 'main', default_branch: 'main')
      backend.write_branch_refs('main', 'sha' => 1)

      expect(File.exist?(File.join(@root, 'pr', 'main', 'branch_refs.json'))).to be(false)
    end

    it 'is a no-op on empty refs' do
      backend = new_backend(branch: 'feat', default_branch: 'main')
      backend.write_branch_refs('feat', {})

      expect(File.exist?(File.join(@root, 'pr', 'feat', 'branch_refs.json'))).to be(false)
    end

    it 'cleans up staging file on rename failure' do
      backend = new_backend(branch: 'feat', default_branch: 'main')
      allow(File).to receive(:rename).and_raise(Errno::ENOSPC)

      expect { backend.write_branch_refs('feat', 'sha1' => 1) }.to raise_error(Errno::ENOSPC)
      dir = File.join(@root, 'pr', 'feat')
      leftover = Dir.exist?(dir) ? Dir.children(dir).grep(/\.tmp\./) : []
      expect(leftover).to be_empty
    end
  end

  describe '#prune!' do
    it 'no-ops when all knobs are nil or zero' do
      expect(new_backend.prune!).to eq(0)
    end

    it 'prunes excess refs beyond count' do
      backend = new_backend
      5.times do |i|
        write_local_cache(run_id: "run-#{i}")
        backend.upload("sha-#{i}")
        sleep 0.05
      end

      removed = backend.prune!(count: 2)

      expect(removed).to eq(3)
      remaining = Dir.children(File.join(@root, 'main'))
      expect(remaining.size).to eq(2)
    end

    it 'prunes refs older than duration_seconds' do
      backend = new_backend
      write_local_cache(run_id: 'run-old')
      backend.upload('old-sha')
      # Backdate the archive mtime to 30 days ago
      old_path = File.join(@root, 'main', 'old-sha', 'cache.tar.gz')
      old_time = Time.now - (30 * 86_400)
      File.utime(old_time, old_time, old_path)

      write_local_cache(run_id: 'run-new')
      backend.upload('new-sha')

      removed = backend.prune!(duration_seconds: 7 * 86_400)

      expect(removed).to eq(1)
      expect(Dir.exist?(File.join(@root, 'main', 'old-sha'))).to be(false)
      expect(Dir.exist?(File.join(@root, 'main', 'new-sha'))).to be(true)
    end

    it 'prunes dead PR branch when pr_branch_ttl exceeded' do
      pr = new_backend(branch: 'feat', default_branch: 'main')
      write_local_cache(run_id: 'run-dead')
      pr.upload('dead-sha')
      old_time = Time.now - (30 * 86_400)
      File.utime(old_time, old_time, File.join(@root, 'pr', 'feat', 'dead-sha', 'cache.tar.gz'))

      removed = pr.prune!(pr_branch_ttl_seconds: 14 * 86_400)

      expect(removed).to eq(1)
      expect(Dir.exist?(File.join(@root, 'pr', 'feat'))).to be(false)
    end

    it 'leaves live PR branch untouched when newest ref is within TTL' do
      pr = new_backend(branch: 'feat', default_branch: 'main')
      write_local_cache(run_id: 'run-live')
      pr.upload('live-sha')

      expect(pr.prune!(pr_branch_ttl_seconds: 14 * 86_400)).to eq(0)
      expect(Dir.exist?(File.join(@root, 'pr', 'feat'))).to be(true)
    end

    it 'returns 0 and logs when whole-branch delete fails' do
      logger = instance_double(RSpecTracer::Logger)
      allow(logger).to receive(:debug)
      allow(logger).to receive(:warn)
      pr = described_class.new(root: @root, branch: 'feat', default_branch: 'main',
                               cache_path: @cache_path, logger: logger)
      write_local_cache(run_id: 'run-dead')
      pr.upload('dead-sha')
      old_time = Time.now - (30 * 86_400)
      File.utime(old_time, old_time, File.join(@root, 'pr', 'feat', 'dead-sha', 'cache.tar.gz'))
      # Stub rm_rf on the branch dir to raise.
      allow(FileUtils).to receive(:rm_rf).and_call_original
      allow(FileUtils).to receive(:rm_rf).with(File.join(@root, 'pr', 'feat')).and_raise(Errno::EACCES)

      expect(pr.prune!(pr_branch_ttl_seconds: 14 * 86_400)).to eq(0)
      expect(logger).to have_received(:warn).with(/failed to prune dead PR branch/)
    end

    it 'pr_branch_ttl is a no-op on main tier' do
      backend = new_backend(branch: 'main', default_branch: 'main')
      write_local_cache(run_id: 'run-main')
      backend.upload('sha1')

      expect(backend.prune!(pr_branch_ttl_seconds: 1)).to eq(0)
    end

    it 'pr_branch_ttl=nil on PR tier skips the dead-PR check (safe-nav else branch)' do
      pr = new_backend(branch: 'feat', default_branch: 'main')
      write_local_cache(run_id: 'run-live')
      pr.upload('sha1')

      expect(pr.prune!(pr_branch_ttl_seconds: nil)).to eq(0)
      expect(Dir.exist?(File.join(@root, 'pr', 'feat'))).to be(true)
    end

    it 'returns 0 when count exceeds existing ref count (no-op short-circuit)' do
      backend = new_backend
      write_local_cache(run_id: 'run-1')
      backend.upload('sha1')

      expect(backend.prune!(count: 50)).to eq(0)
      expect(Dir.exist?(File.join(@root, 'main', 'sha1'))).to be(true)
    end

    it 'returns 0 on a PR tier whose archive directory exists but holds no refs (orphan dir)' do
      pr = new_backend(branch: 'orphan', default_branch: 'main')
      FileUtils.mkdir_p(File.join(@root, 'pr', 'orphan'))

      expect(pr.prune!(pr_branch_ttl_seconds: 14 * 86_400)).to eq(0)
    end

    it 'silently swallows per-ref delete failures when no logger is configured (log_warn nil-logger path)' do
      backend = described_class.new(root: @root, branch: 'main', default_branch: 'main',
                                    cache_path: @cache_path)
      write_local_cache(run_id: 'run-x')
      backend.upload('sha1')
      sleep 0.05
      write_local_cache(run_id: 'run-y')
      backend.upload('sha2')
      allow(FileUtils).to receive(:rm_rf).and_raise(Errno::EACCES)

      expect { backend.prune!(count: 1) }.not_to raise_error
    end

    it 'continues on per-ref delete failures and logs' do
      logger = instance_double(RSpecTracer::Logger)
      allow(logger).to receive(:debug)
      allow(logger).to receive(:warn)
      backend = described_class.new(root: @root, branch: 'main', default_branch: 'main',
                                    cache_path: @cache_path, logger: logger)
      # Upload 2 refs so count: 1 triggers a prune of 1.
      write_local_cache(run_id: 'run-x')
      backend.upload('sha1')
      sleep 0.05
      write_local_cache(run_id: 'run-y')
      backend.upload('sha2')
      # Stub ONLY the ref-dir rm_rf path to raise; let staging cleanup rm_f pass.
      allow(FileUtils).to receive(:rm_rf).and_raise(Errno::EACCES)

      expect { backend.prune!(count: 1) }.not_to raise_error
      expect(logger).to have_received(:warn).at_least(:once)
    end
  end

  describe 'list_refs_in_tier (private) skips non-archive entries' do
    it 'ignores tier subdirs that have no cache.tar.gz archive' do
      # write a half-uploaded ref dir without the archive file
      FileUtils.mkdir_p(File.join(@root, 'main', 'partial-ref'))

      backend = new_backend
      write_local_cache(run_id: 'run-real')
      backend.upload('real-sha')

      expect(backend.send(:list_refs_in_tier, 'main').map(&:first)).to eq(['real-sha'])
    end
  end

  describe 'read_local_run_id (private) graceful nil paths' do
    it 'returns nil when last_run.json holds non-Hash JSON' do
      File.write(File.join(@cache_path, 'last_run.json'), JSON.dump([1, 2, 3]))

      expect(new_backend.send(:read_local_run_id)).to be_nil
    end

    it 'returns nil when last_run.json holds a Hash with a blank run_id' do
      File.write(File.join(@cache_path, 'last_run.json'),
                 JSON.dump('schema_version' => current_schema, 'run_id' => ''))

      expect(new_backend.send(:read_local_run_id)).to be_nil
    end
  end

  describe '#prune_all!' do
    it 'returns 0 when ttl is nil' do
      expect(new_backend.prune_all!).to eq(0)
    end

    it 'returns 0 when pr/ root does not exist' do
      expect(new_backend.prune_all!(pr_branch_ttl_seconds: 3600)).to eq(0)
    end

    it 'deletes dead PR branches but keeps live ones' do
      live = new_backend(branch: 'live', default_branch: 'main')
      write_local_cache(run_id: 'run-live')
      live.upload('live-sha')

      dead = new_backend(branch: 'dead', default_branch: 'main')
      write_local_cache(run_id: 'run-dead')
      dead.upload('dead-sha')
      old_time = Time.now - (30 * 86_400)
      File.utime(old_time, old_time, File.join(@root, 'pr', 'dead', 'dead-sha', 'cache.tar.gz'))

      admin = new_backend # branch/default don't matter for prune_all
      removed = admin.prune_all!(pr_branch_ttl_seconds: 14 * 86_400)

      expect(removed).to eq(1)
      expect(Dir.exist?(File.join(@root, 'pr', 'live'))).to be(true)
      expect(Dir.exist?(File.join(@root, 'pr', 'dead'))).to be(false)
    end

    it 'skips empty branch dirs (no archive files)' do
      FileUtils.mkdir_p(File.join(@root, 'pr', 'empty'))
      admin = new_backend

      expect(admin.prune_all!(pr_branch_ttl_seconds: 3600)).to eq(0)
      expect(Dir.exist?(File.join(@root, 'pr', 'empty'))).to be(true)
    end
  end

  describe '#unbounded_warning' do
    it 'returns nil before any uploads (main tier dir does not yet exist)' do
      # Hits list_refs_in_tier's `return [] unless File.directory?(dir)`
      # short-circuit on a fresh backend.
      expect(new_backend.unbounded_warning).to be_nil
    end

    it 'returns nil when ref count at or below threshold' do
      backend = new_backend
      write_local_cache(run_id: 'run-1')
      backend.upload('sha1')

      expect(backend.unbounded_warning(warn_threshold: 10)).to be_nil
    end

    it 'returns a warning when ref count exceeds threshold' do
      backend = new_backend
      3.times do |i|
        write_local_cache(run_id: "run-#{i}")
        backend.upload("sha-#{i}")
      end

      expect(backend.unbounded_warning(warn_threshold: 2)).to match(/3 refs/)
    end
  end

  describe 'concurrent upload (AC: no corruption)' do
    # Two processes uploading the same ref simultaneously produce an
    # archive that is still valid on download. Last-write-wins via
    # atomic rename. Skipped on non-MRI interpreters where fork() is
    # either unavailable or unreliable.
    it 'survives two concurrent writers to the same ref' do
      skip 'fork unavailable' unless RUBY_ENGINE == 'ruby'

      write_local_cache(run_id: 'run-concurrent')
      # Snapshot the cache path contents to a reference tmp so each
      # forked writer has a consistent view even if another writer is
      # mid-write. The fork semantics copy-on-write the parent's view.
      readers = Array.new(2) do
        fork do
          # exit! bypasses at_exit hooks - keeps the child out of
          # SimpleCov's per-process result writer (which would otherwise
          # record a child-local partial coverage snapshot and stomp on
          # the parent's full coverage after merge). Same reason the
          # parallel_tests spec uses Process._exit in its workers.

          backend = new_backend
          backend.upload('concurrent-sha')
        ensure
          Process.exit!(0)
        end
      end
      readers.each { |pid| Process.wait(pid) }

      # Verify: archive exists, is valid, downloads cleanly.
      archive = File.join(@root, 'main', 'concurrent-sha', 'cache.tar.gz')
      expect(File.file?(archive)).to be(true)

      FileUtils.rm_rf(Dir.glob(File.join(@cache_path, '*')))
      expect(new_backend.download('concurrent-sha')).to be(true)
      expect(File.exist?(File.join(@cache_path, 'last_run.json'))).to be(true)
    end
  end
end
# rubocop:enable RSpec/InstanceVariable, RSpec/ExampleLength, RSpec/MultipleExpectations
