# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'net/http'
require 'open3'
require 'securerandom'

require 'rspec_tracer/remote_cache/s3_backend'
require 'rspec_tracer/storage/schema'

# Integration test: S3Backend round-trip against LocalStack.
#
# Skips gracefully when `awslocal` is not on PATH or LocalStack is
# not reachable on localhost:4566. In CI, `task ci:localstack:ready`
# is a precondition for `task test:integration:remote-cache` - this
# spec runs after the ready+smoke probe passes.
#
# Asserts on the content of what was uploaded / downloaded
# (exit-status checks mask cache-persistence bugs).
# The round-trip proves the key layout
# matches 1.x semantics + the new tier split is coherent.
#
# rubocop:disable RSpec/DescribeClass, RSpec/BeforeAfterAll, RSpec/InstanceVariable
# rubocop:disable RSpec/LeakyConstantDeclaration, RSpec/ExampleLength, RSpec/MultipleExpectations
# rubocop:disable Lint/ConstantDefinitionInBlock, Layout/LineLength
RSpec.describe 'RemoteCache::S3Backend against LocalStack', :integration, :localstack do
  LOCALSTACK_ENDPOINT = ENV.fetch('LOCALSTACK_ENDPOINT', 'http://localhost:4566')

  def localstack_reachable?
    return false unless system('command', '-v', 'awslocal', out: File::NULL, err: File::NULL)

    uri = URI("#{LOCALSTACK_ENDPOINT}/_localstack/health")
    Net::HTTP.start(uri.host, uri.port, open_timeout: 1, read_timeout: 1) do |http|
      response = http.get(uri.request_uri)
      return false unless response.is_a?(Net::HTTPSuccess)

      payload = JSON.parse(response.body)
      %w[available running].include?(payload.dig('services', 's3'))
    end
  rescue StandardError
    false
  end

  before(:all) do
    skip 'LocalStack not reachable; skipping integration specs' unless localstack_reachable?

    @bucket = "rspec-tracer-it-#{SecureRandom.hex(4)}"
    _stdout, stderr, status = Open3.capture3('awslocal', 's3', 'mb', "s3://#{@bucket}")
    raise "failed to create bucket #{@bucket}: #{stderr}" unless status.success?
  end

  after(:all) do
    Open3.capture3('awslocal', 's3', 'rb', "s3://#{@bucket}", '--force') if defined?(@bucket) && @bucket
  end

  let(:current_schema) { RSpecTracer::Storage::Schema::CURRENT }

  around do |example|
    Dir.mktmpdir do |dir|
      @cache_path = dir
      example.run
    end
  end

  def write_local_cache(run_id: 'run-abc-123')
    File.write(
      File.join(@cache_path, 'last_run.json'),
      JSON.pretty_generate('schema_version' => current_schema, 'run_id' => run_id, 'timestamp' => Time.now.utc.iso8601)
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

  def build_backend(branch:, default_branch: 'main', test_suite_id: nil, prefix: nil)
    RSpecTracer::RemoteCache::S3Backend.new(
      bucket: @bucket,
      prefix: prefix || "rspec-tracer-#{SecureRandom.hex(4)}",
      branch: branch,
      default_branch: default_branch,
      test_suite_id: test_suite_id,
      local: true,
      cache_path: @cache_path
    )
  end

  describe 'upload + download round-trip on main tier' do
    it 'preserves last_run.json and the run directory contents' do
      backend = build_backend(branch: 'main', default_branch: 'main')
      write_local_cache(run_id: 'run-main')
      original_content = File.read(File.join(@cache_path, 'run-main', 'all_examples.json'), encoding: 'UTF-8')

      backend.upload('main-sha-1')

      # Clear local cache and re-download into it.
      FileUtils.rm_rf(Dir.glob(File.join(@cache_path, '*')))
      result = backend.download('main-sha-1')

      expect(result).to be(true)
      expect(File.read(File.join(@cache_path, 'run-main', 'all_examples.json'), encoding: 'UTF-8')).to eq(original_content)
      manifest = JSON.parse(File.read(File.join(@cache_path, 'last_run.json')))
      expect(manifest['schema_version']).to eq(current_schema)
    end
  end

  describe 'upload + download round-trip on pr tier' do
    it 'uploads under pr/<branch>/<sha>/ and downloads cleanly' do
      backend = build_backend(branch: 'feat-123', default_branch: 'main')
      write_local_cache(run_id: 'run-pr')

      backend.upload('feat-sha-1')
      # Confirm the key lives under the pr tier as a single archive.
      out, _err, status = Open3.capture3('awslocal', 's3', 'ls',
                                         "s3://#{@bucket}/#{backend.instance_variable_get(:@prefix)}/pr/feat-123/feat-sha-1/",
                                         '--recursive')
      expect(status.success?).to be(true)
      expect(out).to match(/cache\.tar\.gz$/)

      FileUtils.rm_rf(Dir.glob(File.join(@cache_path, '*')))
      expect(backend.download('feat-sha-1')).to be(true)
    end
  end

  describe 'B8 fix: TEST_SUITE_ID alone is valid' do
    it 'scopes uploads under <ref>/<test_suite_id>/ when TEST_SUITE_ID is set without TEST_SUITES' do
      backend = build_backend(branch: 'main', default_branch: 'main', test_suite_id: '3')
      write_local_cache(run_id: 'run-suite-3')

      backend.upload('ts-sha-1')

      out, _err, status = Open3.capture3('awslocal', 's3', 'ls',
                                         "s3://#{@bucket}/#{backend.instance_variable_get(:@prefix)}/main/ts-sha-1/",
                                         '--recursive')
      expect(status.success?).to be(true)
      expect(out).to include('/ts-sha-1/3/cache.tar.gz')
    end
  end

  describe 'schema_version mismatch refuses cache' do
    it 'returns false when the remote cache carries a different schema_version' do
      backend = build_backend(branch: 'main', default_branch: 'main')
      write_local_cache(run_id: 'run-bad-schema')
      # Inject a bad schema into last_run.json before upload.
      File.write(
        File.join(@cache_path, 'last_run.json'),
        JSON.pretty_generate('schema_version' => current_schema + 99, 'run_id' => 'run-bad-schema')
      )
      # Upload the bad cache (backend doesn't validate on upload).
      backend.upload('bad-schema-sha')

      # Clear local. Download should refuse.
      FileUtils.rm_rf(Dir.glob(File.join(@cache_path, '*')))
      expect(backend.download('bad-schema-sha')).to be(false)
      expect(File.exist?(File.join(@cache_path, 'last_run.json'))).to be(false)
    end
  end

  describe 'branch_refs round-trip' do
    it 'writes and reads branch_refs on pr tier' do
      backend = build_backend(branch: 'feat-x', default_branch: 'main')
      refs = { 'sha1' => 1_700_000_000, 'sha2' => 1_700_000_100 }

      backend.write_branch_refs('feat-x', refs)

      expect(backend.branch_refs('feat-x')).to eq(refs)
    end

    it 'returns {} when branch_refs have not been written' do
      backend = build_backend(branch: 'feat-missing', default_branch: 'main')

      expect(backend.branch_refs('feat-missing')).to eq({})
    end
  end

  describe 'pr tier fallback to main tier' do
    it 'downloads from main when the pr tier has no ref but main does' do
      prefix = "fallback-#{SecureRandom.hex(4)}"
      main_backend = build_backend(branch: 'main', default_branch: 'main', prefix: prefix)
      write_local_cache(run_id: 'run-main-fallback')
      main_backend.upload('shared-sha')

      # Now a PR backend tries the same shared-sha - pr tier miss, main tier hit.
      FileUtils.rm_rf(Dir.glob(File.join(@cache_path, '*')))
      pr_backend = build_backend(branch: 'feat-y', default_branch: 'main', prefix: prefix)

      expect(pr_backend.download('shared-sha')).to be(true)
    end
  end

  describe 'retention: cache_retention_count' do
    it 'prunes older refs when count exceeded' do
      prefix = "retention-count-#{SecureRandom.hex(4)}"
      backend = build_backend(branch: 'main', default_branch: 'main', prefix: prefix)
      # Upload 5 refs with 1 second spacing so LastModified orders them.
      5.times do |i|
        write_local_cache(run_id: "run-#{i}")
        backend.upload("sha-#{i}")
        sleep 1
      end

      removed = backend.prune!(count: 2)

      expect(removed).to eq(3)
      out, = Open3.capture3('awslocal', 's3', 'ls', "s3://#{@bucket}/#{prefix}/main/", '--recursive')
      remaining_refs = out.scan(%r{main/(sha-\d+)/}).flatten.uniq
      expect(remaining_refs.size).to eq(2)
      # The newest two (sha-3, sha-4) should survive.
      expect(remaining_refs).to match_array(%w[sha-3 sha-4])
    end
  end

  describe 'retention: pr_branch_ttl on pr tier' do
    it 'leaves a fresh PR branch untouched when TTL is generous' do
      prefix = "retention-pr-#{SecureRandom.hex(4)}"
      backend = build_backend(branch: 'feat-live', default_branch: 'main', prefix: prefix)
      write_local_cache(run_id: 'run-live')
      backend.upload('live-sha')

      removed = backend.prune!(pr_branch_ttl_seconds: 30 * 86_400)

      expect(removed).to eq(0)
    end
  end

  # M8.4-B tree-SHA secondary index: rebase + revert commits produce
  # a different commit-SHA but the SAME tree-SHA. The standard
  # `<tier>/<ref>/cache.tar.gz` layout misses on those scenarios; the
  # tree-SHA pointer at `<tier>/by_tree/<tree_sha>` resolves the tree
  # to the original commit-SHA so the cache hits anyway.
  describe 'tree-SHA secondary index' do
    it 'writes a tree pointer alongside the cache archive on upload' do
      prefix = "tree-sha-write-#{SecureRandom.hex(4)}"
      backend = build_backend(branch: 'main', default_branch: 'main', prefix: prefix)
      write_local_cache(run_id: 'run-tree-1')

      backend.upload('commit-A', tree_sha: 'tree-T')

      out, _err, status = Open3.capture3('awslocal', 's3', 'ls',
                                         "s3://#{@bucket}/#{prefix}/main/by_tree/", '--recursive')
      expect(status.success?).to be(true)
      expect(out).to match(%r{main/by_tree/tree-T$})
    end

    it 'resolves a tree_sha to the original commit on download' do
      prefix = "tree-sha-read-#{SecureRandom.hex(4)}"
      backend = build_backend(branch: 'main', default_branch: 'main', prefix: prefix)
      write_local_cache(run_id: 'run-tree-2')
      original_content = File.read(File.join(@cache_path, 'run-tree-2', 'all_examples.json'), encoding: 'UTF-8')

      backend.upload('commit-A', tree_sha: 'tree-T')

      # New backend instance, fresh local cache - simulate a different
      # commit with the same tree (rebased PR head) asking for the
      # tree by tree_sha. ref='commit-B' has no archive, but the tree
      # pointer resolves to commit-A which DOES.
      FileUtils.rm_rf(Dir.glob(File.join(@cache_path, '*')))
      result = backend.download('commit-B', tree_sha: 'tree-T')

      expect(result).to be(true)
      restored = File.read(File.join(@cache_path, 'run-tree-2', 'all_examples.json'), encoding: 'UTF-8')
      expect(restored).to eq(original_content)
    end

    it 'falls back to direct ref when tree pointer is absent' do
      prefix = "tree-sha-fallback-#{SecureRandom.hex(4)}"
      backend = build_backend(branch: 'main', default_branch: 'main', prefix: prefix)
      write_local_cache(run_id: 'run-tree-3')

      # Upload WITHOUT tree_sha - no pointer written
      backend.upload('commit-X')

      FileUtils.rm_rf(Dir.glob(File.join(@cache_path, '*')))
      # tree_sha is given but pointer doesn't exist; should fall back
      # to direct commit-X lookup and succeed.
      result = backend.download('commit-X', tree_sha: 'tree-missing')

      expect(result).to be(true)
    end

    it 'returns false when both tree pointer AND ref are missing' do
      prefix = "tree-sha-nothing-#{SecureRandom.hex(4)}"
      backend = build_backend(branch: 'main', default_branch: 'main', prefix: prefix)

      result = backend.download('nonexistent-ref', tree_sha: 'nonexistent-tree')

      expect(result).to be(false)
    end

    it 'preserves the existing single-arg API contract' do
      prefix = "tree-sha-noarg-#{SecureRandom.hex(4)}"
      backend = build_backend(branch: 'main', default_branch: 'main', prefix: prefix)
      write_local_cache(run_id: 'run-tree-4')

      # No tree_sha kwarg = pre-M8.4-B behavior; works exactly as before.
      backend.upload('commit-Y')

      FileUtils.rm_rf(Dir.glob(File.join(@cache_path, '*')))
      expect(backend.download('commit-Y')).to be(true)

      # No tree pointer was written.
      out, = Open3.capture3('awslocal', 's3', 'ls',
                            "s3://#{@bucket}/#{prefix}/main/by_tree/", '--recursive')
      expect(out).to be_empty
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/BeforeAfterAll, RSpec/InstanceVariable
# rubocop:enable RSpec/LeakyConstantDeclaration, RSpec/ExampleLength, RSpec/MultipleExpectations
# rubocop:enable Lint/ConstantDefinitionInBlock, Layout/LineLength
