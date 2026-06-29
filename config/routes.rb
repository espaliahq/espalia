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

  # Inbound Slack Events API. Public (auth is the Slack request signature, not a
  # session). Answers the url_verification challenge so the Events request URL
  # can be verified; real events are acked and dropped until the evidence-reply
  # handler is built. See Slack::EventsController.
  post "/slack/events", to: "slack/events#create", as: :slack_events

  # User-facing settings — for now just the connected MCP clients page;
  # other settings live elsewhere historically.
  namespace :settings do
    resources :connected_clients, only: [ :index, :destroy ]
    resource :notifications, only: [ :show, :update ], controller: "notifications"
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

    # Per-tenant Slack install (OAuth v2). install → Slack consent → callback.
    get    "slack/install",  to: "slack_connections#install",  as: :slack_install
    get    "slack/callback", to: "slack_connections#callback", as: :slack_callback
    delete "slack",          to: "slack_connections#destroy",  as: :slack_connection
  end
  # RailsEventStore browser for debugging event streams (global admins only)
  authenticate :user, ->(u) { u.global_admin? } do
    mount RailsEventStore::Browser => "/res"
  end

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # In-app notification inbox (cross-tenant, on the global User).
  resources :notifications, only: [ :index, :update ] do
    collection do
      get :bell
      post :read_all
    end
  end

  # Evidence-request hub — incoming (respond/decline) and outgoing (cancel),
  # plus edit/withdraw of evidence you've authored.
  get "evidence", to: "evidence_hub#show", as: :evidence_hub
  # Request-creation modal (assignment-scoped, read-only renders): the form
  # frame and the debounced typeahead candidates frame.
  get "assessments/:assignment_id/evidence_request_modal",
    to: "evidence_requests#modal", as: :evidence_request_modal
  get "assessments/:assignment_id/evidence_request_candidates",
    to: "evidence_requests#candidates", as: :evidence_request_candidates

  resources :evidence_requests, only: [ :create, :destroy ] do
    member do
      post :respond
      post :decline
    end
  end
  resources :evidence_items, only: [ :update, :destroy ]

  # Unified evidence modal body (server-rendered into the #evidence-modal frame).
  resource :evidence_modal, only: [ :show ], controller: "evidence_modal"

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
    resource :alignment_reopening, only: [ :create ], controller: "assessments/alignment_reopenings"
    resources :delegations, only: [ :create, :destroy ], controller: "assessments/delegations"
    resources :evidence, only: [ :create, :update, :destroy ], controller: "assessments/evidence" do
      collection do
        post :save
      end
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
    resources :illustration_archives, only: [ :create ], controller: "frameworks/illustration_archives"
    resources :capabilities, only: [ :create, :update ], controller: "frameworks/capabilities"
    resources :capability_archives, only: [ :create ], controller: "frameworks/capability_archives"
    resources :capability_bindings, only: [ :index, :create, :update, :destroy ],
              controller: "frameworks/capability_bindings"
    resources :categories,   only: [ :create, :update ], controller: "frameworks/categories"
    resources :category_archives, only: [ :create ], controller: "frameworks/category_archives"
    resources :role_families, only: [ :update ], controller: "frameworks/role_families"
    # Bulk department rename — keyed by the label in the body (no id), so a
    # singular resource (PATCH /frameworks/:framework_id/departments).
    resource :departments, only: [ :update ], controller: "frameworks/departments"
    resources :roles,         only: [ :update ], controller: "frameworks/roles"
    resources :levels,        only: [ :update ], controller: "frameworks/levels"
    resources :expectations, only: [ :create, :update ], controller: "frameworks/expectations"
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
