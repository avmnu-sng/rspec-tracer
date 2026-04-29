# frozen_string_literal: true

class Category < ApplicationRecord
  has_and_belongs_to_many :posts

  validates :name, presence: true, length: { minimum: 2, maximum: 50 },
                   uniqueness: { case_sensitive: false }
  validates :slug, presence: true, uniqueness: true,
                   format: { with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/ }

  before_validation :generate_slug

  scope :alphabetical, -> { order(:name) }
  scope :popular, -> { left_joins(:posts).group(:id).order(Arel.sql("COUNT(posts.id) DESC")) }

  def to_param
    slug
  end

  def post_count
    posts.count
  end

  private

  def generate_slug
    return if slug.present?
    return if name.blank?

    self.slug = name.parameterize
  end
end
