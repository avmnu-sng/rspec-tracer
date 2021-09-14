# frozen_string_literal: true

require_relative '../app/calculator'

RSpec.describe Calculator do
  describe '#add' do
    [
      [1, 2, 3],
      [0, 0, 0],
      [5, 32, 37],
      [-1, -8, -9],
      [10, -10, 0]
    ].each { |a, b, r| it { expect(described_class.add(a, b)).to eq(r) } }
  end

  describe '#sub' do
    [
      [1, 2, -1],
      [10, 0, 10],
      [37, 5, 32],
      [-1, -8, 7],
      [10, 10, 0]
    ].each do |a, b, r|
      it 'performs subtraction' do
        expect(described_class.sub(a, b)).to eq(r)
      end
    end
  end

  describe '#mul' do
    [
      [1, 2, -2],
      [10, 0, 0],
      [5, 7, 35],
      [-1, -8, 8],
      [10, 10, 100]
    ].each do |a, b, r|
      it "multiplies #{a} and #{b} to #{r}" do
        expect(described_class.mul(a, b)).to eq(r)
      end
    end
  end
end
