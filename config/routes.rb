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
    get "entities", to: "entities#index"
    get "entities/:entity_type/records", to: "records#index", as: :entity_records
  end

  # Basic UI
  namespace :ui do
    resources :bulk_actions, only: %i[index new create show] do
      post :cancel, on: :member
    end
    get "entities/:entity_type", to: "records#index", as: :records
  end

  mount Sidekiq::Web => "/sidekiq"

  root "ui/bulk_actions#index"
end
