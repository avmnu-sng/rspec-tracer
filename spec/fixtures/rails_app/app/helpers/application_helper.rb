# frozen_string_literal: true

module ApplicationHelper
  def page_title(*parts)
    ([ content_for(:title).presence ] + parts.compact_blank + [ "Rails App" ])
      .compact_blank
      .join(" \u00B7 ")
  end

  def flash_class(kind)
    case kind.to_s
    when "notice" then "flash flash-info"
    when "alert"  then "flash flash-warning"
    else "flash"
    end
  end
end
