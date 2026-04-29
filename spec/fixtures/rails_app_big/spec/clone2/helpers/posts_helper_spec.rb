# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PostsHelper, type: :helper do
  describe '#formatted_published_at' do
    it 'returns the published_at formatted when published' do
      post = build(:post, :published, published_at: Time.zone.local(2026, 4, 20, 9))
      expect(helper.formatted_published_at(post)).to match(/Apr|20/)
    end

    it 'returns the unpublished label when not published' do
      post = build(:post, :draft)
      expect(helper.formatted_published_at(post)).to eq('Unpublished')
    end

    it 'honors an explicit format option' do
      post = build(:post, :published, published_at: Time.zone.local(2026, 4, 20, 9))
      long = helper.formatted_published_at(post, format: :long)
      short = helper.formatted_published_at(post, format: :short)
      expect(long.length).to be >= short.length
    end
  end

  describe '#post_status_badge' do
    it 'returns the draft badge for drafts' do
      post = build(:post, :draft)
      expect(helper.post_status_badge(post)).to include('post-status-draft')
      expect(helper.post_status_badge(post)).to include('Draft')
    end

    it 'returns the published badge for published posts' do
      post = build(:post, :published)
      expect(helper.post_status_badge(post)).to include('post-status-published')
      expect(helper.post_status_badge(post)).to include('Published')
    end

    it 'returns HTML-safe output' do
      expect(helper.post_status_badge(build(:post, :published))).to be_html_safe
    end
  end

  describe '#post_excerpt' do
    it 'returns the full body when under limit' do
      post = create(:post, body: '<p>short body</p>')
      expect(helper.post_excerpt(post)).to eq('short body')
    end

    it 'truncates over the default 140 char limit' do
      long = 'a' * 200
      post = create(:post, body: "<p>#{long}</p>")
      result = helper.post_excerpt(post)
      expect(result.length).to be <= 141 # 140 + ellipsis
    end

    it 'honors an explicit length option' do
      post = create(:post, body: '<p>' + 'a' * 100 + '</p>')
      expect(helper.post_excerpt(post, length: 20).length).to be <= 21
    end

    it 'returns empty string for blank body' do
      post = create(:post, body: '')
      expect(helper.post_excerpt(post)).to eq('')
    end
  end
end
