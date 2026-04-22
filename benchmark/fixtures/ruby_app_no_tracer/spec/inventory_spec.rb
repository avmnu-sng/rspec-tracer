# frozen_string_literal: true

RSpec.describe Inventory do
  subject(:inv) { described_class.new }

  it { expect(inv).to be_empty }
  it { expect(inv.total).to eq(0) }

  context 'with items' do
    before { inv.add(:apple, 5) }

    it { expect(inv.count(:apple)).to eq(5) }
    it { expect(inv.total).to eq(5) }
    it { expect(inv).not_to be_empty }

    it 'removes items' do
      expect(inv.remove(:apple, 2)).to be(true)
      expect(inv.count(:apple)).to eq(3)
    end

    it 'refuses to over-remove' do
      expect(inv.remove(:apple, 10)).to be(false)
      expect(inv.count(:apple)).to eq(5)
    end
  end
end
