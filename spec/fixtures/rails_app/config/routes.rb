# frozen_string_literal: true

Rails.application.routes.draw do
  resources :users
  resources :posts do
    member { post :publish }
    resources :comments, only: %i[index create destroy]
  end
  resources :categories, only: %i[index show]

  root "posts#index"

  # ActionCable mount point — consumed by the CommentsChannel spec.
  mount ActionCable.server => "/cable"
end
