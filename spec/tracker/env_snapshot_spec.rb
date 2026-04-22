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
end
