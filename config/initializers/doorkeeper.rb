# frozen_string_literal: true

# OAuth 2.1 provider for the MCP server. Authorization-code + PKCE only —
# no client secrets (public clients), no implicit, no password, no refresh.
# Tokens are bound to a single tenant at consent time; see the custom
# Oauth::AuthorizationsController and the MCP design doc.
Doorkeeper.configure do
  orm :active_record

  # Use AR subclasses of ApplicationRecord so Doorkeeper's tables pick up
  # the before_create UUID v7 assignment (the default models inherit from
  # Doorkeeper::ApplicationModel and would otherwise insert with NULL ids).
  application_class  "Mcp::Application"
  access_grant_class "Mcp::AccessGrant"
  access_token_class "Mcp::AccessToken"

  # Resource-owner resolution: the signed-in Devise user. Unauthenticated
  # requests bounce through sign-in and return to the authorization URL.
  resource_owner_authenticator do
    current_user || begin
      session[:user_return_to] = request.fullpath
      redirect_to(new_user_session_url)
    end
  end

  # Admin UI for registering MCP client applications. V1 is global-admin only;
  # tenant-level app registration is a follow-up once we have a tenant admin
  # surface for it. Pundit/AuthorizationContext are not used here because
  # Doorkeeper invokes this before our controllers — fall back to the User
  # boolean directly.
  admin_authenticator do
    if current_user&.global_admin?
      current_user
    else
      redirect_to(new_user_session_url)
    end
  end

  # OAuth 2.1 surface — explicit allow-list.
  grant_flows %w[authorization_code]
  use_refresh_token false           # MCP clients re-authorise; no long-lived refresh tokens
  reuse_access_token                # idempotent token issuance per (app, user, tenant, scope)
  force_pkce                        # PKCE mandatory; rejects code grant without code_verifier
  pkce_code_challenge_methods %w[S256]
  default_scopes  :read
  optional_scopes :write

  access_token_expires_in 1.hour
  authorization_code_expires_in 5.minutes

  # Bearer-only — the MCP server consumes tokens from the Authorization header.
  access_token_methods :from_bearer_authorization

  # `tenant_id` is declared as a custom token attribute so Doorkeeper:
  #   - slices it from the consent-form POST into PreAuthorization
  #   - merges it into the AccessGrant when the authorisation code is issued
  #     (see Doorkeeper::OAuth::Authorization::Code#access_grant_attributes)
  #   - copies it from the grant into the AccessToken at the /oauth/token
  #     exchange (see Doorkeeper::OAuth::AuthorizationCodeRequest)
  # Doorkeeper has no separate "grant attributes" config — the same list
  # governs both surfaces.
  custom_access_token_attributes [ :tenant_id ]

  base_controller "ApplicationController"
end
