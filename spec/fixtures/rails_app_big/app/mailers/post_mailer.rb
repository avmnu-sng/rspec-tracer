# frozen_string_literal: true

class PostMailer < ApplicationMailer
  default from: "notifications@example.com"

  def notify_author(post, comment)
    @post = post
    @comment = comment
    @author = post.user

    mail(
      to: @author.email,
      subject: t("post_mailer.notify_author.subject", title: post.title)
    )
  end

  def weekly_digest(user)
    @user = user
    @posts = user.posts.published.recent.limit(5)

    mail(
      to: user.email,
      subject: t("post_mailer.weekly_digest.subject")
    )
  end
end
