# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CommentsHelper, type: :helper do
  describe '#comment_author_label' do
    it 'returns the admin-labeled name for admins' do
      admin = create(:user, :admin, name: 'Alice Admin')
      comment = build(:comment, user: admin)
      expect(helper.comment_author_label(comment)).to eq('Alice Admin (admin)')
    end

    it 'returns the plain name for members' do
      member = create(:user, name: 'Bob', role: 'member')
      comment = build(:comment, user: member)
      expect(helper.comment_author_label(comment)).to eq('Bob')
    end

    it 'returns the unknown label when user missing' do
      comment = build(:comment)
      comment.user = nil
      expect(helper.comment_author_label(comment)).to eq('Unknown')
    end
  end

  describe '#comment_excerpt' do
    it 'delegates to Comment#excerpt' do
      comment = build(:comment, body: 'a' * 100)
      expect(helper.comment_excerpt(comment).length).to be <= 81
    end

    it 'passes through the limit' do
      comment = build(:comment, body: 'a' * 100)
      expect(helper.comment_excerpt(comment, limit: 20).length).to be <= 21
    end
  end
end
