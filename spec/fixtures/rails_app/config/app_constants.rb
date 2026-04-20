# frozen_string_literal: true

# Constants-only file. Intentionally has no methods — just frozen data.
# 1.x rspec-tracer doesn't observe this file's role as a dependency of any
# example that reads these constants, because `Coverage` on a constants-only
# file only reports load-time execution (which any autoloaded class does).
# 2.0's boot-time snapshot + refinements-aware observers should catch it.
module AppConstants
  DEFAULT_ROLE = "member"

  MAX_POST_TITLE_LENGTH = 200
  MAX_COMMENT_LENGTH = 1000

  SUPPORTED_LOCALES = %i[en es].freeze

  POST_STATUSES = {
    draft: "draft",
    published: "published",
    archived: "archived"
  }.freeze

  COMMENT_MODERATION = {
    auto_approve_after: 10,
    rate_limit_per_hour: 30
  }.freeze
end
