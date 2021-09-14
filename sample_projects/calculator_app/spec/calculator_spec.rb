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
    ].each do |a, b, r|
      it "adds #{a} and #{b} to #{r}" do
        expect(described_class.add(a, b)).to eq(r)
      end
    end
  end

  describe '#sub' do
    [
      [1, 2, -1],
      [10, 0, 10],
      [37, 5, 32],
      [-1, -8, 7],
      [10, 10, 0]
    ].each do |a, b, r|
      it "subs #{b} from #{a} to #{r}" do
        expect(described_class.sub(a, b)).to eq(r)
      end
    end
  end
end
