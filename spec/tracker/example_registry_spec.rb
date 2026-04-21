# frozen_string_literal: true

require 'set'
require 'rspec_tracer/tracker/example_registry'

RSpec.describe RSpecTracer::Tracker::ExampleRegistry do
  subject(:registry) { described_class.new }

  describe 'constants' do
    it 'closes the status enum at 6 values' do
      expect(described_class::STATUSES).to contain_exactly(:passed, :failed, :pending, :interrupted, :flaky, :skipped)
    end

    it 'excludes :passed and :skipped from always_re_run' do
      expect(described_class::ALWAYS_RE_RUN_STATUSES).to contain_exactly(:failed, :flaky, :pending, :interrupted)
    end

    it 'freezes the status list' do
      expect(described_class::STATUSES).to be_frozen
    end

    it 'freezes the always_re_run list' do
      expect(described_class::ALWAYS_RE_RUN_STATUSES).to be_frozen
    end
  end

  describe '#register' do
    it 'adds an example with nil status' do
      registry.register('ex1')

      expect(registry.status_of('ex1')).to be_nil
    end

    it 'marks the example as registered' do
      registry.register('ex1')

      expect(registry.registered?('ex1')).to be(true)
    end

    it 'stores opaque metadata' do
      registry.register('ex1', metadata: { description: 'a test' })

      expect(registry.metadata_of('ex1')).to eq(description: 'a test')
    end

    it 'dups metadata so caller mutation does not leak' do
      meta = { description: 'a test' }
      registry.register('ex1', metadata: meta)
      meta[:description] = 'changed'

      expect(registry.metadata_of('ex1')).to eq(description: 'a test')
    end

    it 'returns self for chaining' do
      expect(registry.register('ex1')).to be(registry)
    end

    it 'is idempotent on repeat registration (first wins)' do
      registry.register('ex1', metadata: { v: 1 })
      registry.register('ex1', metadata: { v: 2 })

      expect(registry.metadata_of('ex1')).to eq(v: 1)
    end

    it 'defaults metadata to an empty hash when omitted' do
      registry.register('ex1')

      expect(registry.metadata_of('ex1')).to eq({})
    end
  end

  describe '#update_status' do
    before { registry.register('ex1') }

    it 'records the status' do
      registry.update_status('ex1', :passed)

      expect(registry.status_of('ex1')).to eq(:passed)
    end

    it 'overwrites a previous status' do
      registry.update_status('ex1', :passed)
      registry.update_status('ex1', :failed)

      expect(registry.status_of('ex1')).to eq(:failed)
    end

    it 'returns self for chaining' do
      expect(registry.update_status('ex1', :passed)).to be(registry)
    end

    it 'raises on an unknown status' do
      expect { registry.update_status('ex1', :bogus) }.to raise_error(ArgumentError, /unknown status/)
    end

    it 'raises on an unregistered example' do
      expect { registry.update_status('nope', :passed) }.to raise_error(ArgumentError, /not registered/)
    end

    described_class::STATUSES.each do |status|
      it "accepts status #{status}" do
        expect { registry.update_status('ex1', status) }.not_to raise_error
      end
    end
  end

  describe '#status_of' do
    it 'returns nil for an unregistered example' do
      expect(registry.status_of('nope')).to be_nil
    end

    it 'returns nil for a registered example that has no status yet' do
      registry.register('ex1')

      expect(registry.status_of('ex1')).to be_nil
    end
  end

  describe '#registered?' do
    it 'is true for a known example' do
      registry.register('ex1')

      expect(registry.registered?('ex1')).to be(true)
    end

    it 'is false for an unknown example' do
      expect(registry.registered?('nope')).to be(false)
    end
  end

  describe '#metadata_of' do
    it 'returns nil for an unregistered example' do
      expect(registry.metadata_of('nope')).to be_nil
    end

    it 'returns a fresh copy per call (mutation does not leak back)' do
      registry.register('ex1', metadata: { v: 1 })
      registry.metadata_of('ex1')[:v] = 99

      expect(registry.metadata_of('ex1')).to eq(v: 1)
    end
  end

  describe '#all_example_ids' do
    it 'returns a Set of registered ids' do
      registry.register('ex1')
      registry.register('ex2')

      expect(registry.all_example_ids).to eq(Set['ex1', 'ex2'])
    end

    it 'is empty for a fresh registry' do
      expect(registry.all_example_ids).to eq(Set.new)
    end
  end

  describe '#size' do
    it 'is zero for a fresh registry' do
      expect(registry.size).to eq(0)
    end

    it 'counts registered examples' do
      registry.register('ex1')
      registry.register('ex2')

      expect(registry.size).to eq(2)
    end
  end

  describe '#ids_with_status' do
    before do
      registry.register('ex1').update_status('ex1', :failed)
      registry.register('ex2').update_status('ex2', :passed)
      registry.register('ex3').update_status('ex3', :failed)
    end

    it 'returns the Set of ids matching the given status' do
      expect(registry.ids_with_status(:failed)).to eq(Set['ex1', 'ex3'])
    end

    it 'returns an empty Set for a status with no matches' do
      expect(registry.ids_with_status(:skipped)).to eq(Set.new)
    end
  end

  describe '#always_re_run_ids' do
    it 'unions the four always-re-run statuses' do
      %i[failed flaky pending interrupted].each do |s|
        registry.register("ex_#{s}").update_status("ex_#{s}", s)
      end

      expect(registry.always_re_run_ids).to eq(Set['ex_failed', 'ex_flaky', 'ex_pending', 'ex_interrupted'])
    end

    it 'excludes :passed examples' do
      registry.register('ex1').update_status('ex1', :passed)

      expect(registry.always_re_run_ids).to eq(Set.new)
    end

    it 'excludes :skipped examples (matches 1.x non-re-run semantics)' do
      registry.register('ex1').update_status('ex1', :skipped)

      expect(registry.always_re_run_ids).to eq(Set.new)
    end

    it 'excludes examples with nil status' do
      registry.register('ex1')

      expect(registry.always_re_run_ids).to eq(Set.new)
    end
  end

  describe 'duplicate detection' do
    it 'is silent when every identity_hash is unique' do
      registry.register('ex1', identity_hash: 'h1')
      registry.register('ex2', identity_hash: 'h2')

      expect(registry.duplicates).to eq({})
    end

    it 'records the original + the colliding example' do
      registry.register('ex1', identity_hash: 'h1')
      registry.register('ex2', identity_hash: 'h1')

      expect(registry.duplicates).to eq('h1' => %w[ex1 ex2])
    end

    it 'accumulates multiple colliders under one identity hash' do
      registry.register('ex1', identity_hash: 'h1')
      registry.register('ex2', identity_hash: 'h1')
      registry.register('ex3', identity_hash: 'h1')

      expect(registry.duplicates['h1']).to eq(%w[ex1 ex2 ex3])
    end

    it 'does not self-collide when the same id registers twice with the same identity_hash' do
      registry.register('ex1', identity_hash: 'h1')
      registry.register('ex1', identity_hash: 'h1')

      expect(registry.duplicates).to eq({})
    end

    it 'ignores identity_hash when omitted' do
      registry.register('ex1')
      registry.register('ex2')

      expect(registry.duplicates).to eq({})
    end

    it 'reports #duplicate? true for a known collision' do
      registry.register('ex1', identity_hash: 'h1')
      registry.register('ex2', identity_hash: 'h1')

      expect(registry.duplicate?('h1')).to be(true)
    end

    it 'reports #duplicate? false when the identity_hash has no collision' do
      registry.register('ex1', identity_hash: 'h1')

      expect(registry.duplicate?('h1')).to be(false)
    end

    it 'returns a fresh copy of the duplicates map (mutation does not leak)' do
      registry.register('ex1', identity_hash: 'h1')
      registry.register('ex2', identity_hash: 'h1')
      registry.duplicates['h1'] << 'injected'

      expect(registry.duplicates['h1']).to eq(%w[ex1 ex2])
    end
  end
end
