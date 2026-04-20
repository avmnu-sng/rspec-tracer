# frozen_string_literal: true

# Reads config/features.json directly via File.read + JSON.parse.
# Parallel to EditorialChecker but exercising the JSON path.
class FeatureFlags
  FLAGS_PATH = Rails.root.join("config/features.json").freeze

  def self.flags
    @flags ||= JSON.parse(File.read(FLAGS_PATH))
  end

  def self.reload!
    @flags = nil
    flags
  end

  def self.enabled?(name)
    flags.dig("feature_flags", name.to_s) == true
  end

  def self.comments_enabled?
    flags.fetch("comments_enabled", false)
  end

  def self.rich_text_enabled?
    flags.fetch("rich_text_enabled", false)
  end

  def self.publish_workflow
    flags.fetch("publish_workflow", {})
  end

  def self.rate_limit(key)
    flags.dig("rate_limits", key.to_s)
  end

  # ENV-branch — the "truly unobservable input" bucket. rspec-tracer can't
  # know this example depends on RAILS_APP_FORCE_REVIEW without an
  # explicit `tracks: { env: ['RAILS_APP_FORCE_REVIEW'] }` declaration.
  def self.require_review?
    return true if ENV["RAILS_APP_FORCE_REVIEW"] == "1"

    publish_workflow.fetch("require_review", false)
  end
end
