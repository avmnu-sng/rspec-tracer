# frozen_string_literal: true

RSpec.describe Calculator do
  subject(:calc) { described_class.new }

  it { expect(calc.add(2, 3)).to eq(5) }
  it { expect(calc.add(-1, 1)).to eq(0) }
  it { expect(calc.subtract(10, 4)).to eq(6) }
  it { expect(calc.subtract(0, 5)).to eq(-5) }
  it { expect(calc.multiply(4, 3)).to eq(12) }
  it { expect(calc.multiply(-2, 5)).to eq(-10) }
  it { expect(calc.divide(10, 4)).to eq(2.5) }
  it { expect { calc.divide(1, 0) }.to raise_error(ZeroDivisionError) }
  it { expect(calc.modulo(10, 3)).to eq(1) }
  it { expect { calc.modulo(1, 0) }.to raise_error(ZeroDivisionError) }
end
