# frozen_string_literal: true

class PostPublishJob < ApplicationJob
  queue_as :default

  retry_on ActiveRecord::Deadlocked, attempts: 3

  def perform(post_id)
    post = Post.find(post_id)
    post.publish! unless post.published?
  end
end
