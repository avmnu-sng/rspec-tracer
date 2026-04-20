# frozen_string_literal: true

class CommentsController < ApplicationController
  before_action :set_post

  def index
    @comments = @post.comments.recent.limit(100)
  end

  def create
    @comment = @post.comments.build(comment_params)

    if @comment.save
      PostMailer.notify_author(@post, @comment).deliver_later
      redirect_to post_path(@post), notice: t(".created")
    else
      redirect_to post_path(@post), alert: @comment.errors.full_messages.to_sentence,
                                    status: :see_other
    end
  end

  def destroy
    @comment = @post.comments.find(params[:id])
    @comment.destroy
    redirect_to post_path(@post), notice: t(".destroyed"), status: :see_other
  end

  private

  def set_post
    @post = Post.find_by!(slug: params[:post_id])
  end

  def comment_params
    params.require(:comment).permit(:body, :user_id)
  end
end
