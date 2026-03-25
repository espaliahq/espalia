Rails.application.routes.draw do
  devise_for :users, controllers: { sessions: "users/sessions" }

  devise_scope :user do
    resource :tenant_switch, only: [ :new, :create ],
      controller: "users/tenant_switches",
      as: :users_tenant_switch
  end
  # RailsEventStore browser for debugging event streams (global admins only)
  authenticate :user, ->(u) { u.global_admin? } do
    mount RailsEventStore::Browser => "/res"
  end

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  resources :assessments, only: [ :index, :show ] do
    member do
      get :matrix
    end
    resources :ratings, only: [ :create ], controller: "assessments/ratings"
  end

  resources :frameworks, only: [ :index, :show ] do
    member do
      get :matrix
    end
    resources :illustrations, only: [ :create, :update ], controller: "frameworks/illustrations"
    resource :settings, only: [ :show, :update ], controller: "frameworks/settings"
  end

  # Defines the root path route ("/")
  root "pages#index"
end
