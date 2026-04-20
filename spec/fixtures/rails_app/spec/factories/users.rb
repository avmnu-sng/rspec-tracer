# frozen_string_literal: true

FactoryBot.define do
  factory :user do
    sequence(:name) { |n| "User #{n}" }
    sequence(:email) { |n| "user#{n}@example.com" }
    role { 'member' }

    trait :admin do
      role { 'admin' }
    end

    trait :guest do
      role { 'guest' }
    end

    trait :activated do
      activated_at { Time.current }
    end
  end
end
