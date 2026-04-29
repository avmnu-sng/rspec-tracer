# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Categories', type: :request do
  describe 'GET /categories' do
    it 'returns 200' do
      get categories_path
      expect(response).to have_http_status(:ok)
    end

    it 'lists categories alphabetically' do
      create(:category, name: 'Zebra')
      create(:category, name: 'Alpha')
      get categories_path
      alpha_idx = response.body.index('Alpha')
      zebra_idx = response.body.index('Zebra')
      expect(alpha_idx).to be < zebra_idx
    end

    it 'shows post count per category' do
      category = create(:category)
      create_list(:post, 2).each { |p| p.categories << category }
      get categories_path
      expect(response.body).to match(/#{Regexp.escape(category.name)}.*2 posts/m)
    end
  end

  describe 'GET /categories/:id' do
    let(:category) { create(:category, name: 'Ruby') }

    it 'returns 200' do
      get category_path(category)
      expect(response).to have_http_status(:ok)
    end

    it 'renders category name' do
      get category_path(category)
      expect(response.body).to include('Ruby')
    end

    it 'lists published posts in the category' do
      post = create(:post, :published, title: 'Published Ruby Post')
      post.categories << category
      get category_path(category)
      expect(response.body).to include('Published Ruby Post')
    end

    it 'omits draft posts' do
      post = create(:post, :draft, title: 'Draft Ruby Post')
      post.categories << category
      get category_path(category)
      expect(response.body).not_to include('Draft Ruby Post')
    end

    it 'shows empty state when no published posts' do
      get category_path(category)
      expect(response.body).to include('No posts in this category')
    end

    it 'returns 404 for missing slug' do
      get category_path('no-such-category')
      expect(response).to have_http_status(:not_found)
    end
  end
end
