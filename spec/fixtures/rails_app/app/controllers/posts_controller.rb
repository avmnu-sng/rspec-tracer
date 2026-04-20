# frozen_string_literal: true

class PostsController < ApplicationController
  before_action :set_post, only: %i[show edit update destroy publish]

  def index
    scope = params[:drafts] == "1" ? Post.drafts : Post.published
    scope = scope.by_author(User.find(params[:user_id])) if params[:user_id].present?
    @posts = scope.recent.limit(50)

    respond_to do |format|
      format.html
      format.json { render :index }
    end
  end

  def show
    respond_to do |format|
      format.html
      format.json { render :show }
    end
  end

  def new
    @post = Post.new
  end

  def create
    @post = Post.new(post_params)

    if @post.save
      PostPublishJob.perform_later(@post.id) if params[:publish] == "1"
      redirect_to @post, notice: t(".created")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @post.update(post_params)
      redirect_to @post, notice: t(".updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @post.destroy
    redirect_to posts_path, notice: t(".destroyed"), status: :see_other
  end

  def publish
    if @post.publish!
      redirect_to @post, notice: t(".published")
    else
      redirect_to @post, alert: t(".already_published")
    end
  end

  private

  def set_post
    @post = Post.find_by!(slug: params[:id])
  end

  def post_params
    params.require(:post).permit(:title, :slug, :user_id, :body, category_ids: [])
  end
end
