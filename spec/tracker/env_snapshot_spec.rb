# frozen_string_literal: true

require 'digest/md5'
require 'set'
require 'rspec_tracer/tracker/env_snapshot'

RSpec.describe RSpecTracer::Tracker::EnvSnapshot do
  let(:env) { { 'API_KEY' => 'secret', 'ROLE_CONFIG' => 'admin' } }
  let(:observer) { described_class.new(env: env) }

  describe '#digest_snapshot' do
    it 'returns an empty Hash when no names are given' do
      expect(observer.digest_snapshot([])).to eq({})
    end

    it 'digests the named env vars with MD5(ENV[name].to_s)' do
      result = observer.digest_snapshot(%w[API_KEY])

      expect(result['API_KEY']).to eq(Digest::MD5.hexdigest('secret'))
    end

    it 'digests missing env vars the same as an empty string' do
      result = observer.digest_snapshot(%w[NOT_SET])

      expect(result['NOT_SET']).to eq(Digest::MD5.hexdigest(''))
    end

    it 'handles multiple keys in one call' do
      result = observer.digest_snapshot(%w[API_KEY ROLE_CONFIG])

      expect(result.keys).to contain_exactly('API_KEY', 'ROLE_CONFIG')
    end

    it 'silently skips empty-string names' do
      result = observer.digest_snapshot(['', 'API_KEY'])

      expect(result.keys).to eq(['API_KEY'])
    end

    it 'coerces non-String names via to_s (Symbol support)' do
      result = observer.digest_snapshot([:API_KEY])

      expect(result.key?('API_KEY')).to be(true)
    end

    it 'accepts a Set argument' do
      result = observer.digest_snapshot(Set.new(%w[API_KEY]))

      expect(result['API_KEY']).to eq(Digest::MD5.hexdigest('secret'))
    end
  end

  describe '#invalidated_keys' do
    it 'is empty when previous matches current' do
      prev = observer.digest_snapshot(%w[API_KEY])

      expect(observer.invalidated_keys(prev, %w[API_KEY])).to eq(Set.new)
    end

    it 'includes keys whose digest differs' do
      prev = { 'API_KEY' => Digest::MD5.hexdigest('other') }

      expect(observer.invalidated_keys(prev, %w[API_KEY])).to eq(Set.new(%w[API_KEY]))
    end

    it 'includes keys missing from the previous snapshot' do
      prev = {}

      expect(observer.invalidated_keys(prev, %w[API_KEY])).to eq(Set.new(%w[API_KEY]))
    end

    it 'returns all tracked names when previous_snapshot is nil' do
      expect(observer.invalidated_keys(nil, %w[API_KEY ROLE_CONFIG]))
        .to eq(Set.new(%w[API_KEY ROLE_CONFIG]))
    end

    it 'only considers names in the names argument (narrow scope)' do
      prev = { 'API_KEY' => 'old', 'OTHER' => 'zero' }

      expect(observer.invalidated_keys(prev, %w[API_KEY])).to eq(Set.new(%w[API_KEY]))
    end

    it 'is empty when names is empty (no-op)' do
      expect(observer.invalidated_keys({ 'API_KEY' => 'old' }, [])).to eq(Set.new)
    end
  end

  describe 'default env source' do
    it 'reads from ::ENV when no injection is provided' do
      observer = described_class.new
      result = observer.digest_snapshot(%w[RSPEC_TRACER_ENV_SPEC_PROBE])

      expect(result['RSPEC_TRACER_ENV_SPEC_PROBE']).to eq(Digest::MD5.hexdigest(''))
    end
  end

  describe 'M5.3 union of config-level + per-example concrete names' do
    let(:env) do
      {
        'AUTH_TOKEN' => 'literal-config',
        'RAILS_ENV' => 'test',
        'RAILS_MAX_THREADS' => '5',
        'PER_EXAMPLE_KEY' => 'p'
      }
    end
    let(:observer) { described_class.new(env: env) }

    it 'digests every concrete name regardless of how it entered the names set' do
      # Mimics Engine post-EnvMatcher.expand: union of config-level
      # concrete names (literal AUTH_TOKEN + wildcard-expanded RAILS_*)
      # plus per-example concrete names (PER_EXAMPLE_KEY).
      names = Set.new(%w[AUTH_TOKEN RAILS_ENV RAILS_MAX_THREADS PER_EXAMPLE_KEY])

      result = observer.digest_snapshot(names)

      expect(result.keys).to match_array(names.to_a)
    end

    # Engine expands "RAILS_*" via EnvMatcher.expand before reaching
    # digest_snapshot — the persisted snapshot carries env keys, not
    # patterns, so the shape stays Hash[name => md5_hex] per the M5.2
    # schema (no wildcard literal survives across runs).
    it 'persists wildcard-expanded names as concrete keys' do
      result = observer.digest_snapshot(%w[RAILS_ENV RAILS_MAX_THREADS])

      expect(result.keys).to match_array(%w[RAILS_ENV RAILS_MAX_THREADS])
    end

    it 'never persists the wildcard pattern itself' do
      result = observer.digest_snapshot(%w[RAILS_ENV RAILS_MAX_THREADS])

      expect(result.keys).not_to include('RAILS_*')
    end

    it 'invalidates a config-level wildcard-expanded key when its value flips' do
      prev = { 'RAILS_ENV' => Digest::MD5.hexdigest('test') }
      changed_env = env.merge('RAILS_ENV' => 'production')
      changed_observer = described_class.new(env: changed_env)

      result = changed_observer.invalidated_keys(prev, %w[RAILS_ENV])

      expect(result).to eq(Set.new(%w[RAILS_ENV]))
    end
  end
end
