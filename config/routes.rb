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
      get :scoring
    end
    resources :ratings, only: [ :create ], controller: "assessments/ratings"
    resources :manager_ratings, only: [ :create ], controller: "assessments/manager_ratings"
    resources :alignment_ratings, only: [ :create ], controller: "assessments/alignment_ratings"
    resource :alignment_start, only: [ :create ], controller: "assessments/alignment_starts"
    resource :alignment_completion, only: [ :create ], controller: "assessments/alignment_completions"
  end

  resources :frameworks, only: [ :index, :show ] do
    member do
      get :matrix
      get :edit
      get "edit/matrix" => "frameworks#edit_matrix", as: :edit_matrix
    end
    resources :illustrations, only: [ :create, :update ], controller: "frameworks/illustrations"
    resources :capabilities, only: [ :update ], controller: "frameworks/capabilities"
    resources :categories,   only: [ :update ], controller: "frameworks/categories"
    resources :expectations, only: [ :update ], controller: "frameworks/expectations"
    resource :settings, only: [ :show, :update ], controller: "frameworks/settings"
    resources :suggestions, only: [ :index, :show, :create, :destroy ], controller: "frameworks/suggestions" do
      member do
        post :approve
        post :reject
        patch :amend
      end
    end
  end

  resources :assessment_cycles, only: [ :index, :show, :new, :create ] do
    member do
      post :close
    end
    resources :enrollments, only: [ :create, :destroy ],
                            controller: "assessment_cycles/enrollments" do
      collection do
        post :bulk
      end
    end
  end

  resources :integrations, only: [ :index, :show ] do
    member do
      post :sync
    end
  end

  # Defines the root path route ("/")
  root "pages#index"
end
