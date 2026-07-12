# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'securerandom'
require 'tmpdir'

require 'rspec_tracer/remote_cache/redis_backend'
require 'rspec_tracer/storage/schema'

# Integration test: RedisBackend round-trip against a real Redis
# server. Skips gracefully when `redis` gem is missing or localhost:6379
# is unreachable, so the task graph does not break for local dev
# without Redis. CI provides a `redis:` services container (see
# `.github/workflows/lint-and-specs.yml`); specs here run after that
# wakes up.
#
# REDIS_URL overrides the default. We use db 15 (an uncommon choice)
# to isolate from other local tooling on the same Redis instance.
#
# Asserts on the content of what was uploaded / downloaded
# (exit-status-only checks mask cache-persistence bugs).
#
# rubocop:disable RSpec/DescribeClass, RSpec/BeforeAfterAll, RSpec/InstanceVariable
# rubocop:disable RSpec/LeakyConstantDeclaration, RSpec/ExampleLength, RSpec/MultipleExpectations
# rubocop:disable Lint/ConstantDefinitionInBlock
RSpec.describe 'RemoteCache::RedisBackend against localhost Redis', :integration, :redis do
  REDIS_URL = ENV.fetch('REDIS_URL', 'redis://localhost:6379/15')

  def redis_reachable?
    require 'redis'
    client = Redis.new(url: REDIS_URL, timeout: 1)
    client.ping == 'PONG'
  rescue LoadError, StandardError
    false
  ensure
    client&.close
  end

  before(:all) do
    skip 'Redis not reachable; skipping integration specs' unless redis_reachable?

    require 'redis'
    @prefix = "rspec-tracer-it-#{SecureRandom.hex(4)}"
    @client = Redis.new(url: REDIS_URL)
    # Start clean on this prefix in case a prior aborted run left keys.
    flush_prefix
  end

  after(:all) do
    flush_prefix if defined?(@client) && @client
    @client&.close
  end

  def flush_prefix
    cursor = 0
    loop do
      cursor, keys = @client.scan(cursor, match: "#{@prefix}:*", count: 200)
      @client.del(*keys) unless keys.empty?
      break if cursor.to_i.zero?
    end
  end

  let(:current_schema) { RSpecTracer::Storage::Schema::CURRENT }

  around do |example|
    Dir.mktmpdir do |dir|
      @cache_path = dir
      example.run
    end
  end

  before do
    # Isolate each example from state left by previous ones. All tests
    # share @prefix via before(:all), so without this reset the retention
    # + prune_all tests see leftover keys from round-trip specs and
    # mis-count deletions.
    flush_prefix
  end

  def build_backend(branch:, default_branch: 'main', test_suite_id: nil)
    RSpecTracer::RemoteCache::RedisBackend.new(
      prefix: @prefix,
      branch: branch,
      default_branch: default_branch,
      test_suite_id: test_suite_id,
      cache_path: @cache_path,
      url: REDIS_URL
    )
  end

  def write_local_cache(run_id: 'run-abc-123')
    File.write(
      File.join(@cache_path, 'last_run.json'),
      JSON.pretty_generate('schema_version' => current_schema, 'run_id' => run_id, 'timestamp' => Time.now.utc.iso8601)
    )
    FileUtils.mkdir_p(File.join(@cache_path, run_id))
    File.write(File.join(@cache_path, run_id, 'all_examples.json'),
               JSON.pretty_generate('examples' => { 'ex1' => 'passed' }))
    File.write(File.join(@cache_path, run_id, 'dependency.json'),
               JSON.pretty_generate('ex1' => ['lib/foo.rb']))
  end

  describe 'upload + download round-trip on main tier' do
    it 'preserves last_run.json and the run directory contents' do
      backend = build_backend(branch: 'main', default_branch: 'main')
      write_local_cache(run_id: 'run-main')
      original_content = File.read(File.join(@cache_path, 'run-main', 'all_examples.json'))

      backend.upload('main-sha-1')

      FileUtils.rm_rf(Dir.glob(File.join(@cache_path, '*')))

      expect(backend.download('main-sha-1')).to be(true)
      expect(File.read(File.join(@cache_path, 'run-main', 'all_examples.json'))).to eq(original_content)
      manifest = JSON.parse(File.read(File.join(@cache_path, 'last_run.json')))
      expect(manifest['schema_version']).to eq(current_schema)
    end
  end

  describe 'upload + download round-trip on pr tier' do
    it 'uploads under pr:<branch>:<sha> and downloads cleanly' do
      backend = build_backend(branch: 'feat-redis-1', default_branch: 'main')
      write_local_cache(run_id: 'run-pr')

      backend.upload('feat-sha-1')

      # Inspect Redis directly to confirm the key lives where we expect.
      expect(@client.exists?("#{@prefix}:pr:feat-redis-1:feat-sha-1")).to be(true)

      FileUtils.rm_rf(Dir.glob(File.join(@cache_path, '*')))
      expect(backend.download('feat-sha-1')).to be(true)
    end
  end

  describe 'schema_version mismatch refuses cache' do
    it 'returns false when the remote cache carries a different schema_version' do
      backend = build_backend(branch: 'main', default_branch: 'main')
      write_local_cache(run_id: 'run-bad-schema')
      # Inject bad schema before upload.
      File.write(
        File.join(@cache_path, 'last_run.json'),
        JSON.pretty_generate('schema_version' => current_schema + 99, 'run_id' => 'run-bad-schema')
      )
      backend.upload('bad-schema-sha')

      FileUtils.rm_rf(Dir.glob(File.join(@cache_path, '*')))
      expect(backend.download('bad-schema-sha')).to be(false)
      expect(File.exist?(File.join(@cache_path, 'last_run.json'))).to be(false)
    end
  end

  describe 'branch_refs round-trip' do
    it 'writes and reads branch_refs on pr tier via Redis string key' do
      backend = build_backend(branch: 'feat-refs', default_branch: 'main')
      refs = { 'sha1' => 1_700_000_000, 'sha2' => 1_700_000_100 }

      backend.write_branch_refs('feat-refs', refs)

      expect(backend.branch_refs('feat-refs')).to eq(refs)
    end

    it 'returns {} when branch_refs have not been written' do
      backend = build_backend(branch: 'feat-missing', default_branch: 'main')

      expect(backend.branch_refs('feat-missing')).to eq({})
    end
  end

  describe 'pr tier fallback to main tier' do
    it 'downloads from main when the pr tier has no ref but main does' do
      main_backend = build_backend(branch: 'main', default_branch: 'main')
      write_local_cache(run_id: 'run-main-fallback')
      main_backend.upload('shared-sha')

      FileUtils.rm_rf(Dir.glob(File.join(@cache_path, '*')))
      pr_backend = build_backend(branch: 'feat-fallback', default_branch: 'main')

      expect(pr_backend.download('shared-sha')).to be(true)
    end
  end

  describe 'retention: cache_retention_count' do
    it 'prunes older refs when count exceeded' do
      backend = build_backend(branch: 'main', default_branch: 'main')
      5.times do |i|
        write_local_cache(run_id: "run-#{i}")
        backend.upload("count-sha-#{i}")
        sleep 0.05
      end

      removed = backend.prune!(count: 2)

      expect(removed).to eq(3)
      remaining = (0..4).map { |i| "count-sha-#{i}" }
        .select { |sha| @client.exists?("#{@prefix}:main:#{sha}") }
      expect(remaining.size).to eq(2)
      # The newest two survive; they are the last two uploaded.
      expect(remaining).to include('count-sha-3', 'count-sha-4')
    end
  end

  describe 'retention: pr_branch_ttl on pr tier' do
    it 'leaves a fresh PR branch untouched when TTL is generous' do
      backend = build_backend(branch: 'feat-live', default_branch: 'main')
      write_local_cache(run_id: 'run-live')
      backend.upload('live-sha')

      removed = backend.prune!(pr_branch_ttl_seconds: 30 * 86_400)

      expect(removed).to eq(0)
      expect(@client.exists?("#{@prefix}:pr:feat-live:live-sha")).to be(true)
    end
  end

  describe 'prune_all! cross-tier cleanup' do
    it 'deletes dead branches but keeps live ones' do
      # live
      live = build_backend(branch: 'live-all', default_branch: 'main')
      write_local_cache(run_id: 'run-live-all')
      live.upload('live-all-sha')
      live.write_branch_refs('live-all', 'live-all-sha' => Time.now.to_i)

      # dead: backdate the _timestamp manually to simulate an old ref
      dead = build_backend(branch: 'dead-all', default_branch: 'main')
      write_local_cache(run_id: 'run-dead-all')
      dead.upload('dead-all-sha')
      old_ts = (Time.now.to_i - (30 * 86_400)).to_s
      @client.hset("#{@prefix}:pr:dead-all:dead-all-sha", '_timestamp', old_ts)
      dead.write_branch_refs('dead-all', 'dead-all-sha' => old_ts.to_i)

      admin = build_backend(branch: 'main', default_branch: 'main')
      removed = admin.prune_all!(pr_branch_ttl_seconds: 14 * 86_400)

      expect(removed).to eq(1)
      expect(@client.exists?("#{@prefix}:pr:live-all:live-all-sha")).to be(true)
      # Dead branch keys should be gone: both the cache hash and branch_refs
      expect(@client.exists?("#{@prefix}:pr:dead-all:dead-all-sha")).to be(false)
      expect(@client.exists?("#{@prefix}:pr:dead-all:branch_refs")).to be(false)
    end
  end

  describe 'ttl: per-key EXPIRE (atomic with HSET inside MULTI)' do
    def build_backend_with_ttl(branch:, ttl:, default_branch: 'main')
      RSpecTracer::RemoteCache::RedisBackend.new(
        prefix: @prefix, branch: branch, default_branch: default_branch,
        cache_path: @cache_path, url: REDIS_URL, ttl: ttl
      )
    end

    it 'sets TTL via EXPIRE atomic with the upload (verified via Redis TTL command)' do
      backend = build_backend_with_ttl(branch: 'main', ttl: 600)
      write_local_cache(run_id: 'run-ttl')
      backend.upload('ttl-sha')

      ttl_remaining = @client.ttl("#{@prefix}:main:ttl-sha")
      # Allow 1s slop for upload + Redis round-trip; Redis returns the
      # remaining TTL in seconds (positive), -1 if no TTL, -2 if missing.
      expect(ttl_remaining).to be_between(1, 600)
    end

    it 'omits TTL when ttl: nil (Redis reports no TTL = -1)' do
      backend = build_backend(branch: 'main')
      write_local_cache(run_id: 'run-no-ttl')
      backend.upload('no-ttl-sha')

      expect(@client.ttl("#{@prefix}:main:no-ttl-sha")).to eq(-1)
    end

    it 'expires the key after the TTL elapses (small TTL + sleep)' do
      backend = build_backend_with_ttl(branch: 'main', ttl: 1)
      write_local_cache(run_id: 'run-expire')
      backend.upload('expire-sha')

      sleep 1.5

      expect(@client.exists?("#{@prefix}:main:expire-sha")).to be(false)
    end
  end

  describe 'pr_branches sidecar SET (PR-tier upload telemetry)' do
    it 'SADDs the branch into <prefix>:pr_branches on PR-tier upload' do
      pr = build_backend(branch: 'feat-side', default_branch: 'main')
      write_local_cache(run_id: 'run-side')
      pr.upload('side-sha')

      expect(@client.smembers("#{@prefix}:pr_branches")).to include('feat-side')
    end

    it 'does NOT SADD on main-tier upload (sidecar is PR-tier only)' do
      backend = build_backend(branch: 'main', default_branch: 'main')
      write_local_cache(run_id: 'run-main-side')
      backend.upload('main-side-sha')

      expect(@client.smembers("#{@prefix}:pr_branches")).to be_empty
    end

    it 'accumulates multiple PR branches as they each upload' do
      branches = %w[feat-a feat-b feat-c]
      branches.each_with_index do |b, i|
        write_local_cache(run_id: "run-#{i}")
        build_backend(branch: b, default_branch: 'main').upload("sha-#{i}")
      end

      expect(@client.smembers("#{@prefix}:pr_branches")).to match_array(branches)
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/BeforeAfterAll, RSpec/InstanceVariable
# rubocop:enable RSpec/LeakyConstantDeclaration, RSpec/ExampleLength, RSpec/MultipleExpectations
# rubocop:enable Lint/ConstantDefinitionInBlock
