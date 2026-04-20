# frozen_string_literal: true

RSpec.describe Discount do
  it 'applies 20% off 100.00' do
    expect(described_class.new(20).apply(100)).to eq(80.0)
  end

  it 'applies 0% (no change)' do
    expect(described_class.new(0).apply(50)).to eq(50.0)
  end

  it 'applies 100% (free)' do
    expect(described_class.new(100).apply(75)).to eq(0.0)
  end

  it 'describes itself' do
    expect(described_class.new(15).describe).to eq('15% off')
  end

  it 'rejects out-of-range' do
    expect { described_class.new(150) }.to raise_error(ArgumentError)
  end

  it 'rejects negative' do
    expect { described_class.new(-5) }.to raise_error(ArgumentError)
  end
end
