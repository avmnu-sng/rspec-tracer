# frozen_string_literal: true

class Post < ApplicationRecord
  belongs_to :user
  has_many :comments, dependent: :destroy
  has_and_belongs_to_many :categories
  has_rich_text :body

  validates :title, presence: true, length: { minimum: 3, maximum: 200 }
  validates :slug, presence: true, uniqueness: true,
                   format: { with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/ }

  before_validation :generate_slug

  scope :published, -> { where.not(published_at: nil) }
  scope :drafts, -> { where(published_at: nil) }
  scope :recent, -> { order(created_at: :desc) }
  scope :by_author, ->(user) { where(user: user) }

  def published?
    published_at.present?
  end

  def draft?
    !published?
  end

  def publish!
    return false if published?

    update!(published_at: Time.current)
  end

  def unpublish!
    return false if draft?

    update!(published_at: nil)
  end

  def comment_count
    comments.count
  end

  def to_param
    slug
  end

  private

  def generate_slug
    return if slug.present?
    return if title.blank?

    base = title.parameterize
    candidate = base
    counter = 1
    while self.class.where(slug: candidate).where.not(id: id).exists?
      candidate = "#{base}-#{counter}"
      counter += 1
    end
    self.slug = candidate
  end
end
