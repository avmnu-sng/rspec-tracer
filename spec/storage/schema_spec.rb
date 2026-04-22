# frozen_string_literal: true

require 'rspec_tracer/storage/schema'

RSpec.describe RSpecTracer::Storage::Schema do
  describe 'CURRENT' do
    it 'is 3 (M3.7 added Snapshot.boot_set; prior v2 shape is not backward-readable)' do
      expect(described_class::CURRENT).to eq(3)
    end
  end

  describe 'SUPPORTED' do
    it 'contains exactly the CURRENT version (no legacy migrators in 2.0)' do
      expect(described_class::SUPPORTED).to eq([described_class::CURRENT])
    end

    it 'is frozen so callers cannot mutate the compatibility set' do
      expect(described_class::SUPPORTED).to be_frozen
    end
  end

  describe '.supported?' do
    it 'is true for the CURRENT version' do
      expect(described_class.supported?(described_class::CURRENT)).to be(true)
    end

    it 'is false for a future version' do
      expect(described_class.supported?(described_class::CURRENT + 1)).to be(false)
    end

    it 'is false for an unstamped 1.x cache (nil)' do
      expect(described_class.supported?(nil)).to be(false)
    end

    it 'is false for a string that stringifies to the current number' do
      expect(described_class.supported?(described_class::CURRENT.to_s)).to be(false)
    end

    it 'is false for a negative integer' do
      expect(described_class.supported?(-1)).to be(false)
    end

    it 'is false for zero' do
      expect(described_class.supported?(0)).to be(false)
    end
  end
end
