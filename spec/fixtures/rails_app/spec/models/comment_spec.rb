# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Comment, type: :model do
  describe 'validations' do
    subject(:comment) { build(:comment) }

    it { is_expected.to be_valid }

    context 'with body' do
      it 'is required' do
        comment.body = nil
        expect(comment).not_to be_valid
      end

      it 'rejects empty string' do
        comment.body = ''
        expect(comment).not_to be_valid
      end

      it 'rejects length > 1000' do
        comment.body = 'a' * 1001
        expect(comment).not_to be_valid
      end

      it 'accepts length 1' do
        comment.body = 'a'
        expect(comment).to be_valid
      end

      it 'accepts length 1000' do
        comment.body = 'a' * 1000
        expect(comment).to be_valid
      end
    end

    context 'when user missing' do
      it 'is invalid' do
        comment.user = nil
        expect(comment).not_to be_valid
      end
    end

    context 'when post missing' do
      it 'is invalid' do
        comment.post = nil
        expect(comment).not_to be_valid
      end
    end
  end

  describe 'associations' do
    it 'belongs to user' do
      comment = create(:comment)
      expect(comment.user).to be_a(User)
    end

    it 'belongs to post' do
      comment = create(:comment)
      expect(comment.post).to be_a(Post)
    end
  end

  describe 'scopes' do
    describe '.recent' do
      it 'orders newest first' do
        post = create(:post)
        older = create(:comment, post: post, created_at: 1.day.ago)
        newer = create(:comment, post: post, created_at: 1.hour.ago)
        expect(described_class.recent).to eq([ newer, older ])
      end
    end

    describe '.for_post' do
      it 'returns only comments for given post' do
        post = create(:post)
        other_post = create(:post)
        mine = create(:comment, post: post)
        create(:comment, post: other_post)
        expect(described_class.for_post(post)).to contain_exactly(mine)
      end
    end
  end

  describe '#excerpt' do
    let(:comment) { build(:comment) }

    it 'returns full body when under limit' do
      comment.body = 'short body'
      expect(comment.excerpt).to eq('short body')
    end

    it 'truncates over default limit (80)' do
      comment.body = 'a' * 100
      result = comment.excerpt
      expect(result.length).to be <= 81 # 80 + ellipsis
      expect(result).to end_with('…')
    end

    it 'respects custom limit' do
      comment.body = 'a' * 50
      result = comment.excerpt(20)
      expect(result.length).to be <= 21
    end

    it 'appends single-char ellipsis, not three dots' do
      comment.body = 'a' * 100
      expect(comment.excerpt).not_to include('...')
      expect(comment.excerpt).to include('…')
    end

    it 'strips trailing whitespace before ellipsis' do
      comment.body = "#{'a' * 78} "
      expect(comment.excerpt(79)).not_to match(/\s…\z/)
    end
  end

  describe 'broadcasting (after_create_commit)' do
    it 'broadcasts to the post channel' do
      post = create(:post)
      user = create(:user)
      allow(ActionCable.server).to receive(:broadcast)
      create(:comment, post: post, user: user)
      expect(ActionCable.server).to have_received(:broadcast).with(
        "comments:#{post.id}", hash_including(id: kind_of(Integer), user: user.display_name)
      )
    end
  end
end
