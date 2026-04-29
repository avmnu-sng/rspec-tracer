# frozen_string_literal: true

FactoryBot.define do
  factory :post do
    association :user
    sequence(:title) { |n| "Post #{n}" }
    body { '<p>Sample content.</p>' }

    trait :published do
      published_at { Time.current }
    end

    trait :draft do
      published_at { nil }
    end

    trait :with_comments do
      transient do
        comment_count { 3 }
      end

      after(:create) do |post, evaluator|
        create_list(:comment, evaluator.comment_count, post: post)
      end
    end

    trait :with_categories do
      transient do
        category_count { 2 }
      end

      after(:create) do |post, evaluator|
        post.categories = create_list(:category, evaluator.category_count)
      end
    end
  end
end
