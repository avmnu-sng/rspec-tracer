# frozen_string_literal: true

module UsersHelper
  def user_avatar_url(user, size: 64)
    return nil if user.blank?

    digest = Digest::MD5.hexdigest(user.email.to_s.downcase)
    "https://www.gravatar.com/avatar/#{digest}?s=#{size}&d=identicon"
  end

  def role_badge(user)
    content_tag(:span, t("users.roles.#{user.role}"), class: "badge role-#{user.role}")
  end

  def activation_status(user)
    if user.activated?
      t("users.activation.activated_at", time: l(user.activated_at, format: :short))
    else
      t("users.activation.pending")
    end
  end
end
