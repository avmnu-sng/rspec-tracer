# frozen_string_literal: true

# Reads config/editorial_guidelines.yml directly via YAML.load_file.
# That direct I/O is the "blind spot" the 2.0 tracker's I/O hooks target.
class EditorialChecker
  GUIDELINES_PATH = Rails.root.join("config/editorial_guidelines.yml").freeze
  WELCOME_BANNER_PATH = Rails.root.join("lib/copy/welcome_banner.txt").to_s.freeze

  def self.guidelines
    @guidelines ||= YAML.load_file(GUIDELINES_PATH, permitted_classes: [ Symbol ])
  end

  def self.reload!
    @guidelines = nil
    guidelines
  end

  def self.forbidden_words
    guidelines.fetch("forbidden_words", [])
  end

  def self.tone_allowed?(tone)
    guidelines.dig("tone", "allowed").to_a.include?(tone.to_s)
  end

  def self.violates_forbidden_words?(text)
    return false if text.blank?

    lowered = text.downcase
    forbidden_words.any? { |word| lowered.include?(word.downcase) }
  end

  def self.under_post_length?(word_count)
    min = guidelines.dig("length", "post", "min_words")
    max = guidelines.dig("length", "post", "max_words")
    return false if min && word_count < min
    return false if max && word_count > max

    true
  end

  def self.welcome_banner
    File.read(WELCOME_BANNER_PATH)
  end

  # Uses IO.read (not File.read) to exercise the distinct blind-spot path.
  # 2.0's I/O hooks prepend both File and IO; 1.x's Coverage-only approach
  # catches neither. Path is a frozen constant so CodeQL's
  # rb/non-constant-kernel-open doesn't false-positive.
  def self.welcome_banner_via_io
    IO.read(WELCOME_BANNER_PATH)
  end
end
