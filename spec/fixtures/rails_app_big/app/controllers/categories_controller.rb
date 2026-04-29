# frozen_string_literal: true

class CategoriesController < ApplicationController
  before_action :set_category, only: :show

  def index
    @categories = Category.alphabetical
  end

  def show
    @posts = @category.posts.published.recent.limit(50)
  end

  private

  def set_category
    @category = Category.find_by!(slug: params[:id])
  end
end
