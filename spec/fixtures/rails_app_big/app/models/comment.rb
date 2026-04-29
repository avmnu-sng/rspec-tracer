# frozen_string_literal: true

class Comment < ApplicationRecord
  belongs_to :user
  belongs_to :post

  validates :body, presence: true, length: { minimum: 1, maximum: 1000 }

  scope :recent, -> { order(created_at: :desc) }
  scope :for_post, ->(post) { where(post: post) }

  after_create_commit :broadcast_to_post

  def excerpt(limit = 80)
    return body if body.length <= limit

    "#{body[0, limit].rstrip}…"
  end

  private

  def broadcast_to_post
    ActionCable.server.broadcast("comments:#{post_id}", {
                                   id: id,
                                   user: user.display_name,
                                   body: excerpt
                                 })
  end
end
