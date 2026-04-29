# frozen_string_literal: true

module CategoriesHelper
  def category_tag(category)
    content_tag(:span, category.name, class: "category-tag category-#{category.slug}")
  end
end
