# frozen_string_literal: true

Rails.application.routes.draw do
  # MCP Streamable HTTP endpoint — single POST that handles all JSON-RPC
  # methods (initialize / tools/list / tools/call). Bearer-token auth via
  # Doorkeeper; see Mcp::ServerController.
  post "/mcp", to: "mcp/server#create", as: :mcp_server

  # OAuth discovery — public, unauthenticated. Lets MCP clients hit /mcp
  # cold and follow the WWW-Authenticate pointer all the way to a token
  # without any manual config beyond the bare server url.
  get "/.well-known/oauth-protected-resource",
    to: "mcp/well_known#oauth_protected_resource", as: :oauth_protected_resource
  get "/.well-known/oauth-authorization-server",
    to: "mcp/well_known#oauth_authorization_server", as: :oauth_authorization_server

  # OAuth 2.0 Dynamic Client Registration (RFC 7591). Public; MCP clients
  # register themselves so users don't paste client ids around.
  post "/oauth/register", to: "mcp/client_registrations#create", as: :oauth_register

  # User-facing settings — for now just the connected MCP clients page;
  # other settings live elsewhere historically.
  namespace :settings do
    resources :connected_clients, only: [ :index, :destroy ]
  end

  # In-app approval surface for high-stakes MCP tools. The MCP server
  # returns a URL routed here when a client invokes a tool declared
  # `approval :in_app`; the user reviews and confirms here, not in the
  # MCP client. See Mcp::ApprovalsController.
  scope :mcp do
    resources :approvals, only: [ :show ], controller: "mcp/approvals", as: :mcp_approval do
      member do
        post :approve
        post :reject
      end
    end
  end

  # OAuth provider (Doorkeeper). PKCE-only, authorization-code only.
  # `controllers:` swaps the consent screen for our Phlex view with a
  # tenant picker. `skip_controllers:` drops surfaces we don't need yet
  # (token info, user-facing authorized_applications — folded into
  # the upcoming "Connected MCP clients" settings page instead).
  use_doorkeeper do
    controllers authorizations: "oauth/authorizations"
    skip_controllers :authorized_applications, :token_info
  end
  devise_for :users, controllers: {
    sessions: "users/sessions",
    omniauth_callbacks: "users/omniauth_callbacks"
  }

  devise_scope :user do
    resource :tenant_switch, only: [ :new, :create ],
      controller: "users/tenant_switches",
      as: :users_tenant_switch
  end

  # Tenant-admin "view as another user". Read-only, within-tenant. Start
  # (create) takes a tenant_user_id; stop (destroy) ends the session.
  resource :impersonation, only: [ :create, :destroy ], controller: "impersonations"

  namespace :tenant do
    root to: "dashboard#show", as: :root

    resource :theme, only: [ :show, :update ], controller: "themes"

    resources :users, only: [ :index, :show, :update ] do
      resources :collaborators,
                only: [ :create, :destroy ],
                controller: "users/collaborators"
      member do
        get :collaborator_scope_picker
      end
    end

    resources :integrations, only: [ :index, :show ] do
      member do
        post :sync
      end
    end
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
    resources :delegations, only: [ :create, :destroy ], controller: "assessments/delegations"
    resources :evidence, only: [ :create, :update, :destroy ], controller: "assessments/evidence" do
      member do
        post :add_link
        post :remove_link
      end
    end
    resource :activity, only: [ :show ], controller: "assessments/activity"
    resources :comments, only: [ :create, :update, :destroy ], controller: "assessments/comments"
  end

  # Individually-addressable comments. Currently resolves
  # assessment-cell comments to their assessment page with the
  # relevant cell focused; future commentable types (growth plans,
  # focus areas) will branch here too.
  resources :comments, only: [ :show ]

  resources :frameworks, only: [ :index, :show ] do
    member do
      get :matrix
      get :edit
      get "edit/matrix" => "frameworks#edit_matrix", as: :edit_matrix
    end
    resources :illustrations, only: [ :create, :update ], controller: "frameworks/illustrations"
    resources :capabilities, only: [ :create, :update ], controller: "frameworks/capabilities"
    resources :capability_archives, only: [ :create ], controller: "frameworks/capability_archives"
    resources :categories,   only: [ :create, :update ], controller: "frameworks/categories"
    resources :expectations, only: [ :update ], controller: "frameworks/expectations"
    resource :settings, only: [ :show, :update ], controller: "frameworks/settings"
    resource :publication, only: [ :new, :create ], controller: "frameworks/publications"
    resources :migration_mappings, only: [ :create ], controller: "frameworks/migration_mappings"
    resource :activity, only: [ :show ], controller: "frameworks/activity"
    resources :collaborators,
              only: [ :index, :create, :destroy ],
              controller: "frameworks/collaborators" do
      collection do
        get :scope_picker
      end
    end
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
      patch :rename
      patch :change_type
      patch :set_planned_end
      # Cohort progress roll-up — broader audience than the admin-only
      # management surface (any manager, scoped to their subtree).
      get :cohort, to: "assessment_cycles/cohorts#show"
    end
    resources :enrollments, only: [ :create, :destroy ],
                            controller: "assessment_cycles/enrollments" do
      collection do
        post :bulk
      end
    end
  end

  # Home dashboard — composable, role-aware card grid (replaces the old
  # root redirect). Cards lazy-load their content via the card route.
  root "home#show"
  get "home/cards/:card(/:key)", to: "home#card", as: :home_card
end
