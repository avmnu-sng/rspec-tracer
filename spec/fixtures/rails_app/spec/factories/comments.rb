# frozen_string_literal: true

FactoryBot.define do
  factory :comment do
    association :user
    association :post
    sequence(:body) { |n| "Comment body #{n} with enough content to exist." }
  end
end
