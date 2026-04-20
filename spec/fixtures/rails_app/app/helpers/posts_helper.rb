# frozen_string_literal: true

module PostsHelper
  def formatted_published_at(post, format: :short)
    return t("posts.unpublished") unless post.published?

    l(post.published_at, format: format)
  end

  def post_status_badge(post)
    key = post.published? ? "published" : "draft"
    content_tag(:span, t("posts.statuses.#{key}"), class: "badge post-status-#{key}")
  end

  def post_excerpt(post, length: 140)
    return "" if post.body.blank?

    text = post.body.to_plain_text
    text.length > length ? "#{text[0, length].rstrip}…" : text
  end
end
