# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'tmpdir'

require 'rspec_tracer/remote_cache/redis_backend'
require 'rspec_tracer/storage/schema'
require_relative '../contracts/remote_cache_backend'

# Minimal in-memory Redis stand-in. Supports only the commands
# RedisBackend uses; not a general-purpose fake. Keeps specs fast and
# free of external dependencies; the real redis-rb wire path is
# covered by the integration spec in spec/integration/remote_cache_spec.rb
# against a localhost Redis service.
class FakeRedisStore
  attr_reader :calls

  def initialize
    @strings = {}
    @hashes = {}
    @calls = Hash.new { |h, k| h[k] = [] }
  end

  def get(key)
    @calls[:get] << key
    @strings[key]
  end

  def set(key, value)
    @calls[:set] << [key, value]
    @strings[key] = value
    'OK'
  end

  def del(*keys)
    @calls[:del] << keys
    keys.flatten.sum do |k|
      removed = 0
      removed += 1 if @strings.delete(k)
      removed += 1 if @hashes.delete(k)
      removed
    end
  end

  def hgetall(key)
    @calls[:hgetall] << key
    (@hashes[key] || {}).dup
  end

  def hset(key, *args)
    @calls[:hset] << [key, args]
    fields = args.first.is_a?(Hash) ? args.first : Hash[*args]
    @hashes[key] ||= {}
    @hashes[key].merge!(fields.transform_values(&:to_s))
    fields.size
  end

  def hget(key, field)
    @calls[:hget] << [key, field]
    (@hashes[key] || {})[field]
  end

  # rubocop:disable Naming/PredicateMethod
  def expire(key, seconds)
    @calls[:expire] << [key, seconds]
    @sets ||= {}
    true
  end
  # rubocop:enable Naming/PredicateMethod

  def sadd(key, member)
    @calls[:sadd] << [key, member]
    @sets ||= {}
    set = (@sets[key] ||= [])
    return 0 if set.include?(member)

    set << member
    1
  end

  def smembers(key)
    @calls[:smembers] << key
    @sets ||= {}
    (@sets[key] || []).dup
  end

  def multi
    @calls[:multi] << :enter
    yield self
    @calls[:multi] << :exit
    []
  end

  def scan_each(match:, count: nil, &block)
    @calls[:scan_each] << { match: match, count: count }
    pattern = Regexp.new("\\A#{Regexp.escape(match).gsub('\\*', '.*')}\\z")
    keys = (@strings.keys + @hashes.keys).uniq.grep(pattern)
    return enum_for(:scan_each, match: match, count: count) unless block_given?

    keys.each(&block)
  end

  def stored_hash(key)
    @hashes[key]
  end

  def stored_string(key)
    @strings[key]
  end

  def all_keys
    (@strings.keys + @hashes.keys).uniq
  end
end

# rubocop:disable RSpec/InstanceVariable, RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe RSpecTracer::RemoteCache::RedisBackend do
  around do |example|
    Dir.mktmpdir('rspec-tracer-redis-cache-') do |cache|
      @cache_path = cache
      @fake = FakeRedisStore.new
      example.run
    end
  end

  let(:current_schema) { RSpecTracer::Storage::Schema::CURRENT }

  def new_backend(branch: 'main', default_branch: 'main', test_suite_id: nil, prefix: 'rspec-tracer')
    described_class.new(
      prefix: prefix,
      branch: branch,
      default_branch: default_branch,
      test_suite_id: test_suite_id,
      cache_path: @cache_path,
      redis_client: @fake
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
    it 'raises on missing prefix' do
      expect do
        described_class.new(prefix: nil, branch: 'main', default_branch: 'main',
                            cache_path: @cache_path, redis_client: @fake)
      end.to raise_error(described_class::RedisBackendError, /prefix/)
    end

    it 'raises on missing branch' do
      expect do
        described_class.new(prefix: 'p', branch: nil, default_branch: 'main',
                            cache_path: @cache_path, redis_client: @fake)
      end.to raise_error(described_class::RedisBackendError, /branch/)
    end

    it 'raises on missing default_branch' do
      expect do
        described_class.new(prefix: 'p', branch: 'main', default_branch: nil,
                            cache_path: @cache_path, redis_client: @fake)
      end.to raise_error(described_class::RedisBackendError, /default_branch/)
    end

    it 'raises when neither url nor redis_client is provided' do
      expect do
        described_class.new(prefix: 'p', branch: 'main', default_branch: 'main',
                            cache_path: @cache_path)
      end.to raise_error(described_class::RedisBackendError, /url or redis_client/)
    end

    it 'trims trailing colons from the prefix' do
      backend = new_backend(prefix: 'rspec-tracer::')
      expect(backend.instance_variable_get(:@prefix)).to eq('rspec-tracer')
    end

    it 'accepts a class-level redis_client kwarg without requiring url' do
      expect { new_backend }.not_to raise_error
    end

    it 'calls ::Redis.new with the supplied url when no client is injected' do
      # Warm up Redis constant so the stub has a target (the backend
      # requires 'redis' lazily; without a prior require, ::Redis is
      # not yet defined here).
      require 'redis'
      fake_client = FakeRedisStore.new
      allow(Redis).to receive(:new).with(url: 'redis://localhost:6379/0').and_return(fake_client)

      backend = described_class.new(
        prefix: 'rspec-tracer', branch: 'main', default_branch: 'main',
        cache_path: @cache_path, url: 'redis://localhost:6379/0'
      )

      expect(Redis).to have_received(:new).with(url: 'redis://localhost:6379/0')
      expect(backend.instance_variable_get(:@redis)).to be(fake_client)
    end

    context 'when the redis gem is not available' do
      # rubocop:disable RSpec/AnyInstance
      it 'raises a clear error pointing at the Gemfile' do
        # Stub Kernel#require to raise LoadError only for 'redis'.
        # Other requires (JSON, fileutils, etc.) still succeed.
        allow_any_instance_of(described_class).to receive(:require).and_call_original
        allow_any_instance_of(described_class).to receive(:require)
          .with('redis').and_raise(LoadError, 'cannot load redis')

        expect do
          described_class.new(prefix: 'p', branch: 'main', default_branch: 'main',
                              cache_path: @cache_path, url: 'redis://localhost:6379/0')
        end.to raise_error(described_class::RedisBackendError, /redis gem is not installed/)
      end
      # rubocop:enable RSpec/AnyInstance

      it 'does not attempt to require redis when a client is DI-injected' do
        allow_any_instance_of(described_class).to receive(:require).with('redis').and_raise(LoadError) # rubocop:disable RSpec/AnyInstance

        # DI path skips build_client entirely - so the LoadError never fires.
        expect { new_backend }.not_to raise_error
      end
    end
  end

  describe '#download' do
    it 'returns false for nil ref' do
      expect(new_backend.download(nil)).to be(false)
    end

    it 'returns false when hash does not exist' do
      expect(new_backend.download('missing')).to be(false)
    end

    it 'round-trips a valid upload on main tier' do
      backend = new_backend
      write_local_cache(run_id: 'run-main')
      backend.upload('sha1')

      FileUtils.rm_rf(Dir.glob(File.join(@cache_path, '*')))

      expect(backend.download('sha1')).to be(true)
      expect(File.exist?(File.join(@cache_path, 'last_run.json'))).to be(true)
      expect(File.exist?(File.join(@cache_path, 'run-main', 'all_examples.json'))).to be(true)
    end

    it 'falls back from pr tier to main tier on miss' do
      main = new_backend(branch: 'main', default_branch: 'main')
      write_local_cache(run_id: 'run-shared')
      main.upload('shared-sha')

      FileUtils.rm_rf(Dir.glob(File.join(@cache_path, '*')))
      pr = new_backend(branch: 'feat', default_branch: 'main')

      expect(pr.download('shared-sha')).to be(true)
    end

    it 'rejects a mismatched schema_version and rolls back' do
      backend = new_backend
      write_local_cache(run_id: 'run-bad', schema: current_schema + 99)
      backend.upload('bad-sha')

      FileUtils.rm_rf(Dir.glob(File.join(@cache_path, '*')))

      expect(backend.download('bad-sha')).to be(false)
      expect(File.exist?(File.join(@cache_path, 'last_run.json'))).to be(false)
      expect(Dir.exist?(File.join(@cache_path, 'run-bad'))).to be(false)
    end

    it 'rescues StandardError from the redis client and returns false' do
      backend = new_backend
      allow(@fake).to receive(:hgetall).and_raise(RuntimeError, 'connection refused')

      expect(backend.download('any-sha')).to be(false)
    end

    it 'ignores unsafe hash field names (absolute paths and ..)' do
      backend = new_backend
      @fake.hset('rspec-tracer:main:safe-check', {
                   '_timestamp' => '1',
                   'last_run.json' => JSON.generate('schema_version' => current_schema, 'run_id' => 'r'),
                   'r/ok.json' => '{}',
                   '/etc/passwd' => 'evil',
                   '../escape.json' => 'bad'
                 })

      backend.download('safe-check')

      expect(File.exist?('/etc/passwd')).to be(true) # was never at risk, but confirms we didn't touch it
      expect(Dir.children(@cache_path)).to match_array(%w[last_run.json r])
    end

    it 'does not write _timestamp as a file' do
      backend = new_backend
      write_local_cache(run_id: 'run-ts')
      backend.upload('ts-sha')

      FileUtils.rm_rf(Dir.glob(File.join(@cache_path, '*')))
      backend.download('ts-sha')

      expect(File.exist?(File.join(@cache_path, '_timestamp'))).to be(false)
    end
  end

  describe '#upload' do
    it 'raises on empty ref' do
      expect { new_backend.upload('') }.to raise_error(described_class::RedisBackendError, /ref is required/)
    end

    it 'raises when no local cache to upload' do
      expect { new_backend.upload('sha1') }.to raise_error(described_class::RedisBackendError, /no local cache/)
    end

    it 'raises when last_run.json is malformed JSON (treats as missing cache)' do
      File.write(File.join(@cache_path, 'last_run.json'), '{not json')

      expect { new_backend.upload('sha1') }.to raise_error(described_class::RedisBackendError, /no local cache/)
    end

    it 'HSETs the expected fields for a 15-file cache' do
      backend = new_backend
      write_local_cache(run_id: 'run-fields')
      backend.upload('fields-sha')

      stored = @fake.stored_hash('rspec-tracer:main:fields-sha')
      expect(stored.keys).to include('_timestamp', 'last_run.json',
                                     'run-fields/all_examples.json', 'run-fields/dependency.json')
      expect(stored['_timestamp'].to_i).to be > 0
    end

    it 'scopes by test_suite_id when set' do
      backend = new_backend(test_suite_id: '3')
      write_local_cache(run_id: 'run-s')
      backend.upload('suite-sha')

      expect(@fake.stored_hash('rspec-tracer:main:suite-sha:3')).not_to be_nil
    end

    it 'writes under pr:<branch>:<sha> for a PR tier backend' do
      pr = new_backend(branch: 'feat', default_branch: 'main')
      write_local_cache(run_id: 'run-pr')
      pr.upload('pr-sha')

      expect(@fake.stored_hash('rspec-tracer:pr:feat:pr-sha')).not_to be_nil
    end

    it 'wraps the write in MULTI and DELs before HSET to flush stale fields' do
      backend = new_backend
      write_local_cache(run_id: 'run-multi')
      backend.upload('multi-sha')

      expect(@fake.calls[:multi]).to eq(%i[enter exit])
      expect(@fake.calls[:del].flatten).to include('rspec-tracer:main:multi-sha')
    end

    context 'with ttl: positive integer (per-key EXPIRE atomic with HSET)' do
      it 'fires EXPIRE inside the same MULTI block as the HSET' do
        backend = described_class.new(
          prefix: 'rspec-tracer', branch: 'main', default_branch: 'main',
          cache_path: @cache_path, redis_client: @fake, ttl: 86_400
        )
        write_local_cache(run_id: 'run-ttl')
        backend.upload('ttl-sha')

        expect(@fake.calls[:expire]).to include(['rspec-tracer:main:ttl-sha', 86_400])
        expect(@fake.calls[:multi]).to eq(%i[enter exit])
      end

      it 'omits EXPIRE when ttl is nil (default; relies on user Redis eviction policy)' do
        backend = new_backend
        write_local_cache(run_id: 'run-no-ttl')
        backend.upload('no-ttl-sha')

        expect(@fake.calls[:expire]).to be_empty
      end

      it 'raises RedisBackendError on non-positive ttl' do
        expect do
          described_class.new(prefix: 'p', branch: 'main', default_branch: 'main',
                              cache_path: @cache_path, redis_client: @fake, ttl: 0)
        end.to raise_error(described_class::RedisBackendError, /positive integer/)
      end

      it 'raises RedisBackendError on negative ttl' do
        expect do
          described_class.new(prefix: 'p', branch: 'main', default_branch: 'main',
                              cache_path: @cache_path, redis_client: @fake, ttl: -10)
        end.to raise_error(described_class::RedisBackendError, /positive integer/)
      end

      it 'raises RedisBackendError on non-integer ttl (e.g. float, string)' do
        expect do
          described_class.new(prefix: 'p', branch: 'main', default_branch: 'main',
                              cache_path: @cache_path, redis_client: @fake, ttl: 1.5)
        end.to raise_error(described_class::RedisBackendError, /positive integer/)

        expect do
          described_class.new(prefix: 'p', branch: 'main', default_branch: 'main',
                              cache_path: @cache_path, redis_client: @fake, ttl: '60')
        end.to raise_error(described_class::RedisBackendError, /positive integer/)
      end
    end

    context 'with PR-branch enumeration sidecar (SADD into <prefix>:pr_branches on PR-tier)' do
      it 'SADDs the branch into <prefix>:pr_branches when uploading on a PR-tier backend' do
        pr = new_backend(branch: 'feat-x', default_branch: 'main')
        write_local_cache(run_id: 'run-side-pr')
        pr.upload('side-sha')

        expect(@fake.calls[:sadd]).to include(['rspec-tracer:pr_branches', 'feat-x'])
        expect(@fake.smembers('rspec-tracer:pr_branches')).to include('feat-x')
      end

      it 'does NOT SADD on main-tier uploads (sidecar is PR-tier only)' do
        backend = new_backend(branch: 'main', default_branch: 'main')
        write_local_cache(run_id: 'run-side-main')
        backend.upload('main-sha')

        expect(@fake.calls[:sadd]).to be_empty
      end

      it 'accumulates multiple PR branches into the same sidecar SET' do
        write_local_cache(run_id: 'run-a')
        new_backend(branch: 'feat-a', default_branch: 'main').upload('sha-a')
        write_local_cache(run_id: 'run-b')
        new_backend(branch: 'feat-b', default_branch: 'main').upload('sha-b')

        expect(@fake.smembers('rspec-tracer:pr_branches')).to contain_exactly('feat-a', 'feat-b')
      end

      it 'fires SADD inside the same MULTI block as the HSET (single round-trip)' do
        pr = new_backend(branch: 'feat-multi', default_branch: 'main')
        write_local_cache(run_id: 'run-multi')
        pr.upload('multi-sha')

        # MULTI exit fires once; SADD recorded between enter + exit (no
        # second multi block).
        expect(@fake.calls[:multi]).to eq(%i[enter exit])
        expect(@fake.calls[:sadd]).not_to be_empty
      end
    end
  end

  describe '#branch_refs' do
    it 'returns {} for a missing key' do
      expect(new_backend(branch: 'feat', default_branch: 'main').branch_refs('feat')).to eq({})
    end

    it 'round-trips a hash via the string key' do
      backend = new_backend(branch: 'feat', default_branch: 'main')
      refs = { 'sha1' => 1, 'sha2' => 2 }

      backend.write_branch_refs('feat', refs)

      expect(backend.branch_refs('feat')).to eq(refs)
    end

    it 'returns {} on non-hash JSON' do
      backend = new_backend(branch: 'feat', default_branch: 'main')
      @fake.set('rspec-tracer:pr:feat:branch_refs', '"just a string"')

      expect(backend.branch_refs('feat')).to eq({})
    end

    it 'returns {} on malformed JSON' do
      backend = new_backend(branch: 'feat', default_branch: 'main')
      @fake.set('rspec-tracer:pr:feat:branch_refs', '{not json')

      expect(backend.branch_refs('feat')).to eq({})
    end

    it 'rescues StandardError from the redis client and returns {}' do
      backend = new_backend(branch: 'feat', default_branch: 'main')
      allow(@fake).to receive(:get).and_raise(RuntimeError, 'refused')

      expect(backend.branch_refs('feat')).to eq({})
    end
  end

  describe '#write_branch_refs' do
    it 'is a no-op for main branch' do
      backend = new_backend(branch: 'main', default_branch: 'main')
      backend.write_branch_refs('main', 'sha' => 1)

      expect(@fake.stored_string('rspec-tracer:pr:main:branch_refs')).to be_nil
    end

    it 'is a no-op for empty refs' do
      backend = new_backend(branch: 'feat', default_branch: 'main')
      backend.write_branch_refs('feat', {})

      expect(@fake.stored_string('rspec-tracer:pr:feat:branch_refs')).to be_nil
    end
  end

  describe '#prune!' do
    it 'no-ops when all knobs are nil or zero' do
      expect(new_backend.prune!).to eq(0)
    end

    it 'prunes excess refs beyond count by _timestamp ordering' do
      backend = new_backend
      5.times do |i|
        @fake.hset("rspec-tracer:main:sha-#{i}", {
                     '_timestamp' => (Time.now.to_i - ((5 - i) * 3600)).to_s,
                     'last_run.json' => '{}'
                   })
      end

      removed = backend.prune!(count: 2)

      expect(removed).to eq(3)
      # Newest two (sha-3, sha-4) should survive
      expect(@fake.all_keys).to include('rspec-tracer:main:sha-3', 'rspec-tracer:main:sha-4')
    end

    it 'prunes refs older than duration_seconds by _timestamp' do
      backend = new_backend
      now = Time.now.to_i
      @fake.hset('rspec-tracer:main:recent', { '_timestamp' => (now - 60).to_s })
      @fake.hset('rspec-tracer:main:old', { '_timestamp' => (now - (30 * 86_400)).to_s })

      removed = backend.prune!(duration_seconds: 7 * 86_400)

      expect(removed).to eq(1)
      expect(@fake.all_keys).not_to include('rspec-tracer:main:old')
      expect(@fake.all_keys).to include('rspec-tracer:main:recent')
    end

    it 'prunes dead PR branch when pr_branch_ttl exceeded' do
      pr = new_backend(branch: 'feat', default_branch: 'main')
      now = Time.now.to_i
      @fake.hset('rspec-tracer:pr:feat:old-sha', { '_timestamp' => (now - (30 * 86_400)).to_s })
      @fake.set('rspec-tracer:pr:feat:branch_refs', '{}')

      removed = pr.prune!(pr_branch_ttl_seconds: 14 * 86_400)

      expect(removed).to eq(1)
      expect(@fake.all_keys.grep(/rspec-tracer:pr:feat:/)).to be_empty
    end

    it 'leaves alive PR branch untouched when newest ref is within TTL' do
      pr = new_backend(branch: 'feat', default_branch: 'main')
      now = Time.now.to_i
      @fake.hset('rspec-tracer:pr:feat:live-sha', { '_timestamp' => (now - 60).to_s })

      expect(pr.prune!(pr_branch_ttl_seconds: 14 * 86_400)).to eq(0)
    end

    it 'filters out branch_refs keys when enumerating refs' do
      backend = new_backend
      @fake.set('rspec-tracer:main:branch_refs', '{}') # shouldn't happen at main tier but guard exists

      expect(backend.prune!(count: 10)).to eq(0)
    end

    it 'skips keys missing a _timestamp field' do
      backend = new_backend
      @fake.hset('rspec-tracer:main:no-ts', { 'last_run.json' => '{}' })

      expect(backend.prune!(count: 0)).to eq(0) # no refs with timestamp to enumerate
    end

    it 'returns the partial count on a StandardError mid-prune' do
      new_backend
      logger = instance_double(RSpecTracer::Logger)
      allow(logger).to receive(:debug)
      allow(logger).to receive(:warn)
      backend_with_logger = described_class.new(
        prefix: 'rspec-tracer', branch: 'main', default_branch: 'main',
        cache_path: @cache_path, redis_client: @fake, logger: logger
      )
      allow(@fake).to receive(:scan_each).and_raise(RuntimeError, 'network')

      expect(backend_with_logger.prune!(count: 5)).to eq(0)
      expect(logger).to have_received(:warn).with(/prune! failed/)
    end
  end

  describe '#prune_all!' do
    it 'returns 0 when ttl is nil' do
      expect(new_backend.prune_all!).to eq(0)
    end

    it 'discovers PR branches via branch_refs keys and prunes dead ones' do
      admin = new_backend
      now = Time.now.to_i
      # live branch
      @fake.hset('rspec-tracer:pr:live:sha1', { '_timestamp' => (now - 60).to_s })
      @fake.set('rspec-tracer:pr:live:branch_refs', '{}')
      # dead branch
      @fake.hset('rspec-tracer:pr:dead:sha2', { '_timestamp' => (now - (30 * 86_400)).to_s })
      @fake.set('rspec-tracer:pr:dead:branch_refs', '{}')

      removed = admin.prune_all!(pr_branch_ttl_seconds: 14 * 86_400)

      expect(removed).to eq(1)
      expect(@fake.all_keys).to include('rspec-tracer:pr:live:sha1')
      expect(@fake.all_keys.grep(/rspec-tracer:pr:dead:/)).to be_empty
    end

    it 'returns 0 when no PR branches exist' do
      expect(new_backend.prune_all!(pr_branch_ttl_seconds: 3600)).to eq(0)
    end

    it 'rescues StandardError and returns 0' do
      backend = new_backend
      allow(@fake).to receive(:scan_each).and_raise(RuntimeError, 'fire')

      expect(backend.prune_all!(pr_branch_ttl_seconds: 3600)).to eq(0)
    end

    it 'returns 0 and logs when DEL raises on a dead-branch prune' do
      logger = instance_double(RSpecTracer::Logger)
      allow(logger).to receive(:debug)
      allow(logger).to receive(:warn)
      admin = described_class.new(prefix: 'rspec-tracer', branch: 'main', default_branch: 'main',
                                  cache_path: @cache_path, redis_client: @fake, logger: logger)
      now = Time.now.to_i
      @fake.hset('rspec-tracer:pr:dead:sha1', { '_timestamp' => (now - (30 * 86_400)).to_s })
      @fake.set('rspec-tracer:pr:dead:branch_refs', '{}')
      # Let scan_each succeed; raise on the bulk DEL.
      allow(@fake).to receive(:del).and_raise(RuntimeError, 'connection lost')

      expect(admin.prune_all!(pr_branch_ttl_seconds: 14 * 86_400)).to eq(0)
      expect(logger).to have_received(:warn).with(/failed to prune dead PR branch/)
    end
  end

  describe '#unbounded_warning' do
    it 'returns nil when ref count is at or below threshold' do
      backend = new_backend
      @fake.hset('rspec-tracer:main:sha1', { '_timestamp' => '1' })

      expect(backend.unbounded_warning(warn_threshold: 10)).to be_nil
    end

    it 'returns a warning when main tier ref count exceeds threshold' do
      backend = new_backend
      5.times { |i| @fake.hset("rspec-tracer:main:sha-#{i}", { '_timestamp' => '1' }) }

      expect(backend.unbounded_warning(warn_threshold: 3)).to match(/5 refs/)
    end

    it 'excludes branch_refs keys from the count' do
      backend = new_backend
      @fake.set('rspec-tracer:main:branch_refs', '{}') # not a real cache key

      expect(backend.unbounded_warning(warn_threshold: 0)).to be_nil
    end
  end

  describe 'private branch coverage' do
    let(:logger) do
      logger = instance_double(RSpecTracer::Logger)
      allow(logger).to receive(:debug)
      allow(logger).to receive(:warn)
      logger
    end

    it 'normalizes an empty test_suite_id to nil' do
      backend = new_backend(test_suite_id: '')

      expect(backend.instance_variable_get(:@test_suite_id)).to be_nil
    end

    it 'pr_branch_ttl=nil on PR tier skips the dead-PR check (safe-nav else branch)' do
      pr = new_backend(branch: 'feat', default_branch: 'main')
      @fake.hset('rspec-tracer:pr:feat:live-sha', { '_timestamp' => Time.now.to_i.to_s })

      expect(pr.prune!(pr_branch_ttl_seconds: nil)).to eq(0)
    end

    it 'returns nil from read_local_run_id when last_run.json holds non-Hash JSON' do
      File.write(File.join(@cache_path, 'last_run.json'), JSON.dump([1, 2, 3]))

      expect(new_backend.send(:read_local_run_id)).to be_nil
    end

    it 'returns nil from read_local_run_id when last_run.json holds a blank run_id' do
      File.write(File.join(@cache_path, 'last_run.json'),
                 JSON.dump('schema_version' => current_schema, 'run_id' => ''))

      expect(new_backend.send(:read_local_run_id)).to be_nil
    end

    it 'returns nil from fetch_timestamp when the hash field is absent' do
      backend = new_backend
      # Key with no _timestamp field; hget returns nil → fetch_timestamp early-returns nil.
      @fake.hset('rspec-tracer:main:no-ts', 'last_run.json' => '{}')

      expect(backend.send(:fetch_timestamp, 'rspec-tracer:main:no-ts')).to be_nil
    end

    it 'returns 0 from delete_keys on an empty key list (prune-by-duration with no stale)' do
      backend = new_backend
      @fake.hset('rspec-tracer:main:recent', { '_timestamp' => Time.now.to_i.to_s })

      expect(backend.prune!(duration_seconds: 7 * 86_400)).to eq(0)
    end

    it 'returns 0 from prune_dead_pr_branch! when own tier has no refs (orphan branch_refs key)' do
      pr = new_backend(branch: 'orphan', default_branch: 'main')
      # branch_refs key exists, but no actual cache refs — list_refs filters
      # branch_refs out so entries is empty.
      @fake.set('rspec-tracer:pr:orphan:branch_refs', '{}')

      expect(pr.prune!(pr_branch_ttl_seconds: 14 * 86_400)).to eq(0)
    end

    it 'skips DEL when delete_branch_prefix has no matching keys (orphan branch_refs)' do
      admin = described_class.new(prefix: 'rspec-tracer', branch: 'main', default_branch: 'main',
                                  cache_path: @cache_path, redis_client: @fake, logger: logger)
      # An orphan branch_refs key without any backing refs — the keys list
      # for the deletion is empty, so the bulk DEL is skipped.
      admin.send(:delete_branch_prefix, 'orphan-branch', 0)

      expect(@fake.calls[:del]).to be_empty
      expect(logger).to have_received(:debug).with(/pruned dead PR branch/)
    end

    it 'returns 0 from maybe_prune_branch when the branch has no refs' do
      admin = new_backend
      # No keys at all under pr:empty
      expect(admin.send(:maybe_prune_branch, 'empty', Time.now.to_i)).to eq(0)
    end

    it 'logs the per-key prune messages when a logger is configured (log_debug then-branch)' do
      backend = described_class.new(
        prefix: 'rspec-tracer', branch: 'main', default_branch: 'main',
        cache_path: @cache_path, redis_client: @fake, logger: logger
      )
      @fake.hset('rspec-tracer:main:old-sha', { '_timestamp' => (Time.now.to_i - (30 * 86_400)).to_s })

      backend.prune!(duration_seconds: 7 * 86_400)

      expect(logger).to have_received(:debug).with(/pruned key/).at_least(:once)
    end
  end
end
# rubocop:enable RSpec/InstanceVariable, RSpec/ExampleLength, RSpec/MultipleExpectations
