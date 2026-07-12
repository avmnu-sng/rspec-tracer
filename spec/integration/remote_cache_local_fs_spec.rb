# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'securerandom'
require 'tmpdir'

require 'rspec_tracer/remote_cache/local_fs_backend'
require 'rspec_tracer/storage/schema'

# M8.10: Local-FS remote-cache integration spec.
#
# Mirrors `spec/integration/remote_cache_spec.rb`'s S3Backend
# round-trip shape against a tmpdir-backed Local-FS root. The S3 +
# Redis backends had integration coverage; LocalFs only had unit
# tests in `spec/remote_cache/local_fs_backend_spec.rb` until M8.10
# closed the parity gap.
#
# Asserts on the content of what was uploaded / downloaded
# (exit-status checks mask cache-persistence bugs; only content
# assertions catch them). The round-trip proves the two-tier
# layout matches S3 semantics + the schema_version envelope is
# preserved across the archive boundary.
#
# rubocop:disable RSpec/DescribeClass, RSpec/InstanceVariable
# rubocop:disable RSpec/BeforeAfterAll, RSpec/MultipleExpectations
# rubocop:disable RSpec/ExampleLength
RSpec.describe 'RemoteCache::LocalFsBackend round-trip integration (M8.10)' do
  let(:current_schema) { RSpecTracer::Storage::Schema::CURRENT }

  before(:all) do
    @local_fs_root = Dir.mktmpdir('rspec-tracer-localfs-it')
  end

  after(:all) do
    FileUtils.rm_rf(@local_fs_root) if @local_fs_root
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @cache_path = dir
      example.run
    end
  end

  def write_local_cache(run_id: 'run-abc-123')
    File.write(
      File.join(@cache_path, 'last_run.json'),
      JSON.pretty_generate(
        'schema_version' => current_schema,
        'run_id' => run_id,
        'timestamp' => Time.now.utc.iso8601
      )
    )
    FileUtils.mkdir_p(File.join(@cache_path, run_id))
    File.write(
      File.join(@cache_path, run_id, 'all_examples.json'),
      JSON.pretty_generate('examples' => { 'ex1' => 'passed' })
    )
    File.write(
      File.join(@cache_path, run_id, 'dependency.json'),
      JSON.pretty_generate('ex1' => ['lib/foo.rb'])
    )
  end

  def build_backend(branch:, default_branch: 'main', test_suite_id: nil, root_subdir: nil)
    root = File.join(@local_fs_root, root_subdir || SecureRandom.hex(4))
    RSpecTracer::RemoteCache::LocalFsBackend.new(
      root: root,
      branch: branch,
      default_branch: default_branch,
      test_suite_id: test_suite_id,
      cache_path: @cache_path
    )
  end

  describe 'upload + download round-trip on main tier' do
    it 'preserves last_run.json and the run-dir contents byte-for-byte' do
      backend = build_backend(branch: 'main', default_branch: 'main',
                              root_subdir: "main-tier-#{SecureRandom.hex(4)}")
      write_local_cache(run_id: 'run-main')
      original_content = File.read(File.join(@cache_path, 'run-main', 'all_examples.json'),
                                   encoding: 'UTF-8')

      backend.upload('main-sha-1')

      # Wipe the local cache and re-download into it.
      FileUtils.rm_rf(Dir.glob(File.join(@cache_path, '*')))
      result = backend.download('main-sha-1')

      expect(result).to be(true)
      expect(File.read(File.join(@cache_path, 'run-main', 'all_examples.json'),
                       encoding: 'UTF-8'))
        .to eq(original_content)
      manifest = JSON.parse(File.read(File.join(@cache_path, 'last_run.json')))
      expect(manifest['schema_version']).to eq(current_schema)
    end
  end

  describe 'upload + download round-trip on pr tier' do
    it 'uploads under pr/<branch>/<sha>/ and downloads cleanly' do
      backend = build_backend(branch: 'feat-123', default_branch: 'main',
                              root_subdir: "pr-tier-#{SecureRandom.hex(4)}")
      write_local_cache(run_id: 'run-pr')

      backend.upload('feat-sha-1')

      FileUtils.rm_rf(Dir.glob(File.join(@cache_path, '*')))
      expect(backend.download('feat-sha-1')).to be(true)

      manifest = JSON.parse(File.read(File.join(@cache_path, 'last_run.json')))
      expect(manifest['run_id']).to eq('run-pr')
    end
  end

  describe 'pr-tier download falls back to main-tier on miss' do
    it 'finds the upstream main-tier cache when no pr-tier cache exists for the SHA' do
      shared_root = "shared-#{SecureRandom.hex(4)}"
      main_backend = build_backend(branch: 'main', default_branch: 'main', root_subdir: shared_root)
      write_local_cache(run_id: 'run-main-fallback')
      main_backend.upload('shared-sha-1')

      FileUtils.rm_rf(Dir.glob(File.join(@cache_path, '*')))
      pr_backend = build_backend(branch: 'feat-fallback', default_branch: 'main', root_subdir: shared_root)

      # The PR tier has nothing under feat-fallback/shared-sha-1; the
      # backend should fall back to main/shared-sha-1 and succeed.
      expect(pr_backend.download('shared-sha-1')).to be(true)
      manifest = JSON.parse(File.read(File.join(@cache_path, 'last_run.json')))
      expect(manifest['run_id']).to eq('run-main-fallback')
    end
  end

  describe 'test_suite_id scoping' do
    it 'isolates uploads by test_suite_id (sharded suites do not collide)' do
      shared_root = "sharded-#{SecureRandom.hex(4)}"

      backend_a = build_backend(branch: 'main', default_branch: 'main',
                                test_suite_id: 'shard-a', root_subdir: shared_root)
      write_local_cache(run_id: 'run-shard-a')
      backend_a.upload('multi-shard-sha')

      FileUtils.rm_rf(Dir.glob(File.join(@cache_path, '*')))
      backend_b = build_backend(branch: 'main', default_branch: 'main',
                                test_suite_id: 'shard-b', root_subdir: shared_root)
      write_local_cache(run_id: 'run-shard-b')
      backend_b.upload('multi-shard-sha')

      # Each suite's cache lives in its own shard-A or shard-B path.
      FileUtils.rm_rf(Dir.glob(File.join(@cache_path, '*')))
      expect(backend_a.download('multi-shard-sha')).to be(true)
      expect(JSON.parse(File.read(File.join(@cache_path, 'last_run.json')))['run_id']).to eq('run-shard-a')

      FileUtils.rm_rf(Dir.glob(File.join(@cache_path, '*')))
      expect(backend_b.download('multi-shard-sha')).to be(true)
      expect(JSON.parse(File.read(File.join(@cache_path, 'last_run.json')))['run_id']).to eq('run-shard-b')
    end
  end

  describe 'graceful degradation on malformed remote cache' do
    # The download contract per the lib comment is: "Cleans up
    # partially-extracted state on failure." So a failed download
    # leaves the local cache in a known cold-run-able state, NOT in
    # the prior contents. The user-facing assurance is: download
    # returns false + no raise propagates into the caller (matches
    # the gem-wide graceful-degradation contract).
    it 'returns false without raising when the archive is corrupt' do
      backend = build_backend(branch: 'main', default_branch: 'main',
                              root_subdir: "corrupt-#{SecureRandom.hex(4)}")
      write_local_cache(run_id: 'run-corrupt')
      backend.upload('sha-corrupt')

      # Corrupt the on-remote archive so download has something to fail on.
      archive = Dir.glob(File.join(@local_fs_root, '*', 'main', 'sha-corrupt', 'cache.tar.gz')).first
      raise 'archive missing post-upload' if archive.nil?

      File.write(archive, 'not a real tar.gz')

      expect { @result = backend.download('sha-corrupt') }.not_to raise_error
      expect(@result).to be(false)
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/InstanceVariable
# rubocop:enable RSpec/BeforeAfterAll, RSpec/MultipleExpectations
# rubocop:enable RSpec/ExampleLength
