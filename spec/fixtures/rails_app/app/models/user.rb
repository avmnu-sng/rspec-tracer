# frozen_string_literal: true

class User < ApplicationRecord
  ROLES = %w[admin member guest].freeze

  has_many :posts, dependent: :destroy
  has_many :comments, dependent: :destroy

  validates :name, presence: true, length: { minimum: 2, maximum: 100 }
  validates :email, presence: true,
                    uniqueness: { case_sensitive: false },
                    format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :role, presence: true, inclusion: { in: ROLES }

  before_validation :normalize_email

  scope :activated, -> { where.not(activated_at: nil) }
  scope :admins, -> { where(role: "admin") }
  scope :recently_created, -> { order(created_at: :desc) }

  def activate!
    return false if activated?

    update!(activated_at: Time.current)
  end

  def activated?
    activated_at.present?
  end

  def admin?
    role == "admin"
  end

  def display_name
    name.presence || email.split("@").first
  end

  def to_param
    "#{id}-#{name.parameterize}"
  end

  private

  def normalize_email
    self.email = email.to_s.strip.downcase if email.present?
  end
end
