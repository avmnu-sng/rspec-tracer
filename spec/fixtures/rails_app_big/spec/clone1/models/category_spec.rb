# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Category, type: :model do
  describe 'validations' do
    subject(:category) { build(:category) }

    it { is_expected.to be_valid }

    context 'with name' do
      it 'is required' do
        category.name = nil
        expect(category).not_to be_valid
      end

      it 'rejects length < 2' do
        category.name = 'A'
        expect(category).not_to be_valid
      end

      it 'rejects length > 50' do
        category.name = 'A' * 51
        expect(category).not_to be_valid
      end

      it 'is unique (case-insensitive)' do
        create(:category, name: 'Ruby')
        dupe = build(:category, name: 'ruby')
        expect(dupe).not_to be_valid
      end
    end

    context 'with slug' do
      it 'auto-generates from name' do
        category = build(:category, name: 'Hello World')
        category.valid?
        expect(category.slug).to eq('hello-world')
      end

      it 'is unique' do
        create(:category, slug: 'taken')
        dupe = build(:category, slug: 'taken')
        expect(dupe).not_to be_valid
      end

      it 'rejects slugs with spaces' do
        category = build(:category, name: 'Valid Name', slug: 'bad slug')
        expect(category).not_to be_valid
      end

      it 'rejects slugs with underscores' do
        category = build(:category, name: 'Valid Name', slug: 'bad_slug')
        expect(category).not_to be_valid
      end

      it 'rejects uppercase in slugs' do
        category = build(:category, name: 'Valid Name', slug: 'Bad-Slug')
        expect(category).not_to be_valid
      end

      it 'accepts digits in slugs' do
        category = build(:category, name: 'Valid Name', slug: 'slug-42')
        expect(category).to be_valid
      end
    end
  end

  describe 'callbacks' do
    describe '#generate_slug' do
      it 'runs when slug blank' do
        category = build(:category, name: 'Some Name', slug: '')
        category.valid?
        expect(category.slug).to eq('some-name')
      end

      it 'does not run when slug set' do
        category = build(:category, name: 'Some Name', slug: 'custom')
        category.valid?
        expect(category.slug).to eq('custom')
      end

      it 'does not run when name blank' do
        category = build(:category, name: '')
        category.valid?
        expect(category.slug).to be_blank
      end
    end
  end

  describe 'associations' do
    it 'has and belongs to many posts' do
      category = create(:category)
      post1 = create(:post)
      post2 = create(:post)
      category.posts = [ post1, post2 ]
      expect(category.reload.posts).to contain_exactly(post1, post2)
    end
  end

  describe 'scopes' do
    describe '.alphabetical' do
      it 'orders by name ascending' do
        zebra = create(:category, name: 'Zebra')
        alpha = create(:category, name: 'Alpha')
        middle = create(:category, name: 'Middle')
        expect(described_class.alphabetical).to eq([ alpha, middle, zebra ])
      end
    end

    describe '.popular' do
      it 'orders by post count descending' do
        busy = create(:category)
        quiet = create(:category)
        create_list(:post, 3).each { |p| p.categories << busy }
        expect(described_class.popular.first).to eq(busy)
        expect(described_class.popular.last).to eq(quiet)
      end
    end
  end

  describe '#to_param' do
    it 'returns slug' do
      category = create(:category, name: 'Hello World')
      expect(category.to_param).to eq('hello-world')
    end
  end

  describe '#post_count' do
    it 'counts associated posts' do
      category = create(:category)
      create_list(:post, 3).each { |p| p.categories << category }
      expect(category.post_count).to eq(3)
    end

    it 'is 0 when none associated' do
      expect(create(:category).post_count).to eq(0)
    end
  end
end
