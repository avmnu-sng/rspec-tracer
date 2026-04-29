# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('config/app_constants')

RSpec.describe AppConstants do
  describe 'DEFAULT_ROLE' do
    it 'is the member role' do
      expect(described_class::DEFAULT_ROLE).to eq('member')
    end
  end

  describe 'MAX_POST_TITLE_LENGTH' do
    it 'is 200' do
      expect(described_class::MAX_POST_TITLE_LENGTH).to eq(200)
    end

    it 'matches the Post model validation upper bound' do
      post = build(:post, title: 'a' * described_class::MAX_POST_TITLE_LENGTH)
      expect(post).to be_valid
    end
  end

  describe 'MAX_COMMENT_LENGTH' do
    it 'is 1000' do
      expect(described_class::MAX_COMMENT_LENGTH).to eq(1000)
    end

    it 'matches the Comment model validation upper bound' do
      comment = build(:comment, body: 'a' * described_class::MAX_COMMENT_LENGTH)
      expect(comment).to be_valid
    end
  end

  describe 'SUPPORTED_LOCALES' do
    it 'contains en and es' do
      expect(described_class::SUPPORTED_LOCALES).to contain_exactly(:en, :es)
    end

    it 'is frozen' do
      expect(described_class::SUPPORTED_LOCALES).to be_frozen
    end
  end

  describe 'POST_STATUSES' do
    it 'contains draft / published / archived' do
      expect(described_class::POST_STATUSES.keys).to contain_exactly(:draft, :published, :archived)
    end

    it 'is frozen' do
      expect(described_class::POST_STATUSES).to be_frozen
    end
  end

  describe 'COMMENT_MODERATION' do
    it 'has an auto_approve_after threshold' do
      expect(described_class::COMMENT_MODERATION[:auto_approve_after]).to be_a(Integer)
    end

    it 'has a rate_limit_per_hour value' do
      expect(described_class::COMMENT_MODERATION[:rate_limit_per_hour]).to be_a(Integer)
    end
  end
end
