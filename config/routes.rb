require "sidekiq/web"

Rails.application.routes.draw do
  # JSON API
  scope module: :api, defaults: { format: :json } do
    resources :bulk_actions, path: "bulk-actions", only: %i[index create show] do
      member do
        get :stats
        get :logs
        post :cancel
      end
    end
    resources :contacts, only: %i[index]
    get "entities", to: "entities#index"
  end

  # Basic UI
  namespace :ui do
    resources :bulk_actions, only: %i[index new create show] do
      post :cancel, on: :member
    end
    resources :contacts, only: %i[index]
  end

  mount Sidekiq::Web => "/sidekiq"

  root "ui/bulk_actions#index"
end
