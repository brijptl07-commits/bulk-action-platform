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

  # Any unmatched path/verb outside the UI gets a JSON 404 instead of Rails' HTML error page.
  match "*unmatched", to: "api/base#route_not_found", via: :all, defaults: { format: :json },
                      constraints: ->(req) { !req.path.start_with?("/ui", "/sidekiq", "/assets", "/rails") }
end
