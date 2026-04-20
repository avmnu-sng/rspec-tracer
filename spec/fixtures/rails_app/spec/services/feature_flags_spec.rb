# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FeatureFlags do
  before { described_class.reload! }

  describe '.flags' do
    it 'loads from config/features.json' do
      flags = described_class.flags
      expect(flags).to be_a(Hash)
      expect(flags).to have_key('feature_flags')
      expect(flags).to have_key('rate_limits')
    end

    it 'is memoized' do
      first = described_class.flags
      second = described_class.flags
      expect(first).to be(second)
    end
  end

  describe '.enabled?' do
    it 'is true for a true-valued flag' do
      expect(described_class.enabled?('experimental_digest')).to be(true)
    end

    it 'is false for a false-valued flag' do
      expect(described_class.enabled?('legacy_exports')).to be(false)
    end

    it 'is false for an unknown flag' do
      expect(described_class.enabled?('missing_flag')).to be(false)
    end

    it 'accepts symbols' do
      expect(described_class.enabled?(:experimental_digest)).to be(true)
    end
  end

  describe '.comments_enabled?' do
    it 'reflects the features.json top-level key' do
      expect(described_class.comments_enabled?).to be(true)
    end
  end

  describe '.rich_text_enabled?' do
    it 'reflects the features.json top-level key' do
      expect(described_class.rich_text_enabled?).to be(true)
    end
  end

  describe '.publish_workflow' do
    it 'returns the workflow hash' do
      wf = described_class.publish_workflow
      expect(wf).to have_key('require_review')
      expect(wf).to have_key('auto_notify_authors')
    end
  end

  describe '.rate_limit' do
    it 'returns the requested rate limit' do
      expect(described_class.rate_limit('comments_per_minute')).to eq(5)
      expect(described_class.rate_limit('posts_per_hour')).to eq(20)
    end

    it 'returns nil for unknown keys' do
      expect(described_class.rate_limit('unknown')).to be_nil
    end
  end

  describe '.require_review? (ENV-branch blind-spot exercise)' do
    around do |example|
      before = ENV['RAILS_APP_FORCE_REVIEW']
      example.run
      ENV['RAILS_APP_FORCE_REVIEW'] = before
    end

    it 'reflects the features.json default when ENV is unset' do
      ENV.delete('RAILS_APP_FORCE_REVIEW')
      expect(described_class.require_review?).to be(false)
    end

    it 'is true when RAILS_APP_FORCE_REVIEW=1' do
      ENV['RAILS_APP_FORCE_REVIEW'] = '1'
      expect(described_class.require_review?).to be(true)
    end

    it 'is false for any other ENV value' do
      ENV['RAILS_APP_FORCE_REVIEW'] = '0'
      expect(described_class.require_review?).to be(false)
    end
  end
end
