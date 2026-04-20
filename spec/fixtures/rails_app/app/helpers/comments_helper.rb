# frozen_string_literal: true

module CommentsHelper
  def comment_author_label(comment)
    user = comment.user
    return t("comments.author.unknown") if user.blank?

    if user.admin?
      t("comments.author.admin", name: user.display_name)
    else
      user.display_name
    end
  end

  def comment_excerpt(comment, limit: 80)
    comment.excerpt(limit)
  end
end
