# frozen_string_literal: true

# Property-test bodies legitimately need a little setup before the
# expectation (generator unpacking, factory call); the rubocop-rspec
# defaults are tuned for unit tests with 1 line of body.
# rubocop:disable RSpec/ExampleLength
require 'rspec_tracer/tracker/input'
require 'rantly/rspec_extensions'

ALLOWED_KINDS_LIST = RSpecTracer::Tracker::ALLOWED_INPUT_KINDS.to_a.freeze
IDENTITY_ROOT = '/tmp/project'

# Helper-method indirection keeps property_of generator blocks
# single-line so Style/MultilineBlockChain stays quiet on the chained
# .check(N) do |...| end form.
module InputIdentityGen
  module_function

  def alpha_word
    word = Rantly { string(:alpha) }
    word.empty? ? 'a' : word
  end

  def kind
    Rantly { choose(*ALLOWED_KINDS_LIST) }
  end

  def digest
    Rantly { string(:alnum) }
  end

  def for_name(name, kind:, digest:)
    RSpecTracer::Tracker::Input.for_file(
      path: File.join(IDENTITY_ROOT, "#{name}.rb"),
      kind: kind, digest: digest, root: IDENTITY_ROOT
    )
  end

  # Rantly's property_of block evaluates in Rantly's instance context
  # (so generator DSL like `range` / `choose` resolves). The pair
  # generator lives here so it is reachable from property_of.
  def random_pairs
    Rantly do
      n = range(5, 20)
      Array.new(n) { [choose(*ALLOWED_KINDS_LIST), choose('alpha', 'beta', 'gamma')] }
    end
  end
end

RSpec.describe RSpecTracer::Tracker::Input do
  describe '.for_file identity determinism' do
    it 'depends only on (path, kind), not on digest' do
      property_of { [InputIdentityGen.kind, InputIdentityGen.alpha_word] }.check(100) do |kind, name|
        a = InputIdentityGen.for_name(name, kind: kind, digest: 'one')
        b = InputIdentityGen.for_name(name, kind: kind, digest: 'two')
        expect(a.identity).to eq(b.identity)
      end
    end
  end

  describe 'identity-equal Inputs' do
    it 'are == under identity, eql?, and produce the same hash' do
      property_of { [InputIdentityGen.kind, InputIdentityGen.alpha_word] }.check(100) do |kind, name|
        a = InputIdentityGen.for_name(name, kind: kind, digest: InputIdentityGen.digest)
        b = InputIdentityGen.for_name(name, kind: kind, digest: InputIdentityGen.digest)
        expect(a).to eq(b).and(satisfy { |x| x.eql?(b) }).and(satisfy { |x| x.hash == b.hash })
      end
    end
  end

  describe 'distinct relative paths' do
    it 'produce distinct identities' do
      property_of { [InputIdentityGen.kind, InputIdentityGen.alpha_word, InputIdentityGen.alpha_word] }
        .check(100) do |kind, n_a, n_b|
        next if n_a == n_b

        a = InputIdentityGen.for_name(n_a, kind: kind, digest: 'x')
        b = InputIdentityGen.for_name(n_b, kind: kind, digest: 'x')
        expect(a).not_to eq(b)
      end
    end
  end

  describe 'distinct kinds on the same path' do
    it 'produce distinct identities' do
      property_of { [InputIdentityGen.kind, InputIdentityGen.kind, InputIdentityGen.alpha_word] }
        .check(100) do |k_a, k_b, name|
        next if k_a == k_b

        a = InputIdentityGen.for_name(name, kind: k_a, digest: 'x')
        b = InputIdentityGen.for_name(name, kind: k_b, digest: 'x')
        expect(a.identity).not_to eq(b.identity)
      end
    end
  end

  describe 'Set dedup over a generated population' do
    # A small alphabet is the point — the Set needs real collisions to
    # dedup, so distinct_identities count is usually < pairs count.
    it 'collapses identity-equal Inputs to a single Set entry' do
      property_of { InputIdentityGen.random_pairs }.check(100) do |pairs|
        inputs = pairs.map { |kind, name| InputIdentityGen.for_name(name, kind: kind, digest: 'x') }
        distinct_identities = pairs.map { |k, n| "#{k}:#{n}.rb" }.uniq
        expect(Set.new(inputs).size).to eq(distinct_identities.size)
      end
    end
  end
end
# rubocop:enable RSpec/ExampleLength
