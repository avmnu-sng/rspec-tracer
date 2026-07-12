# frozen_string_literal: true

# Example-identity variance fixture. The original 3 spec files (calculator,
# discount, inventory) only exercise top-level `it { }` patterns under
# a single describe. Real users hit the same Example.from identity-hash
# surface via shared examples (re-included from multiple hosts), shared
# contexts, custom matchers, deeply nested describes, redefined-subject
# contexts, and one-liner `is_expected` chains. This file broadens the
# variance surface so the parallel_tests integration spec
# (spec/integration/parallel_tests_spec.rb) gates cold/warm parity on
# every shape that actually fires in the wild — not just top-level
# anonymous it.
#
# Six patterns covered + one unicode-description regression case.
# The unicode description is constructed at runtime so the source
# stays ASCII-only (mutant's parser rejects non-US-ASCII source;
# spec files aren't in its parser scope today, but keeping the whole
# tree ASCII avoids surprises if that scope ever widens).

RSpec::Matchers.define :be_a_finite_numeric do
  match { |actual| actual.is_a?(Numeric) && actual.finite? }
end

RSpec.shared_examples 'a numeric op result' do
  it { is_expected.to be_a_finite_numeric }
  it { is_expected.to be >= 0 }
end

RSpec.shared_context 'with prepared inventory' do
  let(:inv) do
    Inventory.new.tap do |i|
      i.add(:apple, 5)
      i.add(:banana, 3)
    end
  end

  it { expect(inv.count(:apple)).to eq(5) }
  it { expect(inv.count(:banana)).to eq(3) }
  it { expect(inv).not_to be_empty }
end

RSpec.describe 'anonymous-block variance fixture' do
  # Pattern 1 — shared examples re-included from host A.
  describe Calculator do
    describe '.add (sum of positive ints)' do
      subject { described_class.new.add(2, 3) }

      it_behaves_like 'a numeric op result'
    end
  end

  # Pattern 1 (cont.) — same shared block, different host. The Example.from
  # identity hash must distinguish (host, included_block, position) cleanly
  # across cold + warm so warm_skipped == cold_examples holds.
  describe Discount do
    describe '#apply (positive price)' do
      subject { described_class.new(20).apply(100) }

      it_behaves_like 'a numeric op result'
    end
  end

  # Pattern 2 — shared context with let + anonymous it.
  describe Inventory do
    include_context 'with prepared inventory'
  end

  # Pattern 3 — custom matcher + anonymous one-liner is_expected.
  describe 'custom matcher coverage' do
    subject { Calculator.new.divide(10, 4) }

    it { is_expected.to be_a_finite_numeric }
  end

  # Pattern 4 — deeply nested describes with anonymous it.
  describe Calculator do
    describe '.subtract' do
      describe 'with same operands' do
        it { expect(described_class.new.subtract(7, 7)).to eq(0) }
      end

      describe 'with positive then negative operand' do
        it { expect(described_class.new.subtract(5, -3)).to eq(8) }
      end
    end
  end

  # Pattern 5 — redefined subject inside a nested context.
  describe Discount do
    subject(:discount) { described_class.new(50) }

    it { expect(discount.apply(100)).to eq(50) }

    context 'when reset to zero' do
      subject(:discount) { described_class.new(0) }

      it { expect(discount.apply(100)).to eq(100) }
    end
  end

  # Pattern 6 — one-liner is_expected chain (multiple).
  describe Calculator do
    subject(:multiply_result) { described_class.new.multiply(4, 5) }

    it { is_expected.to eq(20) }
    it { is_expected.to be_a_finite_numeric }
  end

  # Decision (g-yes): unicode in description. Construct "café" at
  # runtime via pack('U*') from integer codepoints so the source file
  # stays ASCII-only. Example.from feeds the description through
  # data.to_json -> Digest::MD5.hexdigest; cold + warm must encode the
  # same bytes for the example_id to round-trip. If the identity hash
  # holds for unicode descriptions this is a useful regression gate;
  # if it breaks, that surfaces another flake source to fix in-session.
  describe 'unicode description regression' do
    description = "computes #{[0x63, 0x61, 0x66, 0xE9].pack('U*')} discount"
    it description do
      expect(Discount.new(25).apply(100)).to eq(75)
    end
  end
end
