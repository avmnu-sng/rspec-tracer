# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Post, type: :model do
  describe 'validations' do
    subject(:post) { build(:post) }

    it { is_expected.to be_valid }

    context 'with title' do
      it 'is required' do
        post.title = nil
        expect(post).not_to be_valid
        expect(post.errors[:title]).to include("can't be blank")
      end

      it 'rejects length < 3' do
        post.title = 'Ab'
        expect(post).not_to be_valid
      end

      it 'rejects length > 200' do
        post.title = 'A' * 201
        expect(post).not_to be_valid
      end

      it 'accepts length 3' do
        post.title = 'Abc'
        expect(post).to be_valid
      end

      it 'accepts length 200' do
        post.title = 'A' * 200
        expect(post).to be_valid
      end
    end

    context 'with slug' do
      it 'auto-generates from title when blank' do
        post = build(:post, title: 'Hello World')
        post.valid?
        expect(post.slug).to eq('hello-world')
      end

      it 'respects explicit slug' do
        post = build(:post, title: 'Hello World', slug: 'custom-slug')
        post.valid?
        expect(post.slug).to eq('custom-slug')
      end

      it 'is unique' do
        create(:post, slug: 'taken-slug')
        dupe = build(:post, slug: 'taken-slug')
        expect(dupe).not_to be_valid
        expect(dupe.errors[:slug]).to include('has already been taken')
      end

      it 'rejects slugs with uppercase letters' do
        post = build(:post, title: 'ok', slug: 'Bad-Slug')
        expect(post).not_to be_valid
      end

      it 'rejects slugs with spaces' do
        post = build(:post, title: 'ok', slug: 'bad slug')
        expect(post).not_to be_valid
      end

      it 'rejects slugs with underscores' do
        post = build(:post, title: 'ok', slug: 'bad_slug')
        expect(post).not_to be_valid
      end

      it 'accepts slugs with hyphens' do
        post = build(:post, title: 'okay', slug: 'good-slug')
        expect(post).to be_valid
      end

      it 'accepts slugs with digits' do
        post = build(:post, title: 'okay', slug: 'slug-42')
        expect(post).to be_valid
      end
    end

    context 'when user is missing' do
      it 'is invalid' do
        post.user = nil
        expect(post).not_to be_valid
      end
    end
  end

  describe 'callbacks' do
    describe '#generate_slug' do
      it 'disambiguates conflicting slugs with a counter' do
        create(:post, title: 'Hello World')
        second = build(:post, title: 'Hello World')
        second.valid?
        expect(second.slug).to eq('hello-world-1')
      end

      it 'walks the counter across multiple conflicts' do
        create(:post, title: 'Hello World')
        create(:post, title: 'Hello World')
        third = build(:post, title: 'Hello World')
        third.valid?
        expect(third.slug).to eq('hello-world-2')
      end

      it 'leaves slug alone when explicitly set' do
        post = build(:post, title: 'Hello World', slug: 'my-slug')
        post.valid?
        expect(post.slug).to eq('my-slug')
      end

      it 'does not touch slug when title blank' do
        post = build(:post, title: '', slug: '')
        post.valid?
        expect(post.slug).to eq('')
      end
    end
  end

  describe 'associations' do
    let(:post) { create(:post) }

    describe 'user' do
      it 'belongs to a user' do
        expect(post.user).to be_a(User)
      end
    end

    describe 'comments' do
      it 'has many comments' do
        c1 = create(:comment, post: post)
        c2 = create(:comment, post: post)
        expect(post.comments).to contain_exactly(c1, c2)
      end

      it 'destroys comments when post destroyed' do
        create_list(:comment, 3, post: post)
        expect { post.destroy }.to change(Comment, :count).by(-3)
      end
    end

    describe 'categories' do
      it 'has and belongs to many categories' do
        cat1 = create(:category)
        cat2 = create(:category)
        post.categories = [ cat1, cat2 ]
        expect(post.reload.categories).to contain_exactly(cat1, cat2)
      end

      it 'removes join records but not categories on destroy' do
        post.categories = create_list(:category, 2)
        expect { post.destroy }.not_to change(Category, :count)
      end
    end

    describe 'body (rich text)' do
      it 'stores rich text content' do
        post = create(:post, body: '<p>rich text</p>')
        expect(post.body.to_s).to include('rich text')
      end

      it 'exposes plain text' do
        post = create(:post, body: '<p>rich <strong>text</strong></p>')
        expect(post.body.to_plain_text).to eq('rich text')
      end
    end
  end

  describe 'scopes' do
    describe '.published' do
      it 'returns only published posts' do
        published = create(:post, :published)
        create(:post, :draft)
        expect(described_class.published).to contain_exactly(published)
      end
    end

    describe '.drafts' do
      it 'returns only draft posts' do
        draft = create(:post, :draft)
        create(:post, :published)
        expect(described_class.drafts).to contain_exactly(draft)
      end
    end

    describe '.recent' do
      it 'orders newest first' do
        older = create(:post, created_at: 2.days.ago)
        newer = create(:post, created_at: 1.hour.ago)
        expect(described_class.recent).to eq([ newer, older ])
      end
    end

    describe '.by_author' do
      let(:user) { create(:user) }

      it 'returns only posts by given user' do
        mine = create(:post, user: user)
        create(:post) # different user
        expect(described_class.by_author(user)).to contain_exactly(mine)
      end

      it 'returns empty when user has no posts' do
        expect(described_class.by_author(user)).to be_empty
      end
    end
  end

  describe '#published?' do
    it 'is true when published_at set' do
      expect(build(:post, :published).published?).to be(true)
    end

    it 'is false when published_at nil' do
      expect(build(:post, :draft).published?).to be(false)
    end
  end

  describe '#draft?' do
    it 'is inverse of published?' do
      expect(build(:post, :published).draft?).to be(false)
      expect(build(:post, :draft).draft?).to be(true)
    end
  end

  describe '#publish!' do
    context 'when draft' do
      it 'sets published_at' do
        post = create(:post, :draft)
        expect { post.publish! }.to change(post, :published_at).from(nil)
      end

      it 'returns truthy' do
        post = create(:post, :draft)
        expect(post.publish!).to be_truthy
      end
    end

    context 'when already published' do
      it 'returns false' do
        post = create(:post, :published)
        expect(post.publish!).to be(false)
      end

      it 'does not change published_at' do
        post = create(:post, :published)
        before = post.published_at
        post.publish!
        expect(post.reload.published_at).to be_within(1.second).of(before)
      end
    end
  end

  describe '#unpublish!' do
    it 'clears published_at when published' do
      post = create(:post, :published)
      expect { post.unpublish! }.to change(post, :published_at).to(nil)
    end

    it 'returns false when already draft' do
      post = create(:post, :draft)
      expect(post.unpublish!).to be(false)
    end
  end

  describe '#comment_count' do
    it 'returns the number of comments' do
      post = create(:post, :with_comments, comment_count: 4)
      expect(post.comment_count).to eq(4)
    end

    it 'is 0 when no comments' do
      expect(create(:post).comment_count).to eq(0)
    end
  end

  describe '#to_param' do
    it 'returns slug' do
      post = create(:post, title: 'Hello World')
      expect(post.to_param).to eq(post.slug)
    end
  end
end
