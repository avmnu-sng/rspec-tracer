# frozen_string_literal: true

require 'rails_helper'

RSpec.describe EditorialChecker do
  before { described_class.reload! }

  describe '.guidelines' do
    it 'loads from config/editorial_guidelines.yml' do
      guidelines = described_class.guidelines
      expect(guidelines).to be_a(Hash)
      expect(guidelines).to have_key('tone')
      expect(guidelines).to have_key('length')
      expect(guidelines).to have_key('forbidden_words')
    end

    it 'is cached across calls (memoized until reload!)' do
      first = described_class.guidelines
      second = described_class.guidelines
      expect(first).to be(second)
    end
  end

  describe '.reload!' do
    it 'resets the memoized guidelines' do
      before_reload = described_class.guidelines
      described_class.reload!
      expect(described_class.guidelines).not_to be(before_reload)
    end
  end

  describe '.forbidden_words' do
    it 'returns the forbidden words list' do
      expect(described_class.forbidden_words).to include('spam')
      expect(described_class.forbidden_words).to include('clickbait')
    end
  end

  describe '.tone_allowed?' do
    it 'returns true for allowed tones' do
      expect(described_class.tone_allowed?('informative')).to be(true)
      expect(described_class.tone_allowed?('technical')).to be(true)
    end

    it 'returns false for disallowed tones' do
      expect(described_class.tone_allowed?('aggressive')).to be(false)
    end

    it 'coerces symbols to strings' do
      expect(described_class.tone_allowed?(:informative)).to be(true)
    end
  end

  describe '.violates_forbidden_words?' do
    it 'returns true when text contains a forbidden word' do
      expect(described_class.violates_forbidden_words?('This is spam content')).to be(true)
    end

    it 'is case-insensitive' do
      expect(described_class.violates_forbidden_words?('this is CLICKBAIT')).to be(true)
    end

    it 'returns false when text is clean' do
      expect(described_class.violates_forbidden_words?('this is a normal post')).to be(false)
    end

    it 'returns false for blank text' do
      expect(described_class.violates_forbidden_words?('')).to be(false)
      expect(described_class.violates_forbidden_words?(nil)).to be(false)
    end
  end

  describe '.under_post_length?' do
    it 'returns false when under the min' do
      expect(described_class.under_post_length?(10)).to be(false)
    end

    it 'returns true when within the range' do
      expect(described_class.under_post_length?(200)).to be(true)
    end

    it 'returns false when over the max' do
      expect(described_class.under_post_length?(10_000)).to be(false)
    end
  end

  describe '.welcome_banner' do
    it 'reads from lib/copy/welcome_banner.txt' do
      expect(described_class.welcome_banner).to include('Welcome to the Rails App')
    end

    it 'returns a non-empty string' do
      expect(described_class.welcome_banner).not_to be_empty
    end
  end

  describe '.welcome_banner_via_io (IO.read blind-spot exercise)' do
    it 'reads the same content via IO.read' do
      expect(described_class.welcome_banner_via_io).to eq(described_class.welcome_banner)
    end
  end
end
