# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CategoriesHelper, type: :helper do
  describe '#category_tag' do
    it 'wraps the name in a span with slug-specific class' do
      category = build(:category, name: 'Ruby', slug: 'ruby')
      result = helper.category_tag(category)
      expect(result).to include('Ruby')
      expect(result).to include('category-ruby')
    end

    it 'returns HTML-safe output' do
      category = build(:category, slug: 'ruby')
      expect(helper.category_tag(category)).to be_html_safe
    end
  end
end
