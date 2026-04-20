# frozen_string_literal: true

class CommentsChannel < ApplicationCable::Channel
  def subscribed
    post = Post.find_by(slug: params[:post_slug])
    if post
      stream_from "comments:#{post.id}"
    else
      reject
    end
  end

  def unsubscribed
    stop_all_streams
  end
end
