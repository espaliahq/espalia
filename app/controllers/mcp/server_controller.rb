# frozen_string_literal: true

# Single endpoint for the MCP Streamable HTTP transport. Accepts a JSON-RPC
# 2.0 request, dispatches via {Mcp::RequestHandler}, and returns the
# response as JSON.
#
# Auth: requires a Doorkeeper bearer token (PKCE-issued via the OAuth
# consent flow). The token's `tenant_id` seeds ActsAsTenant + a fresh
# AuthorizationContext for this request — controllers and policies see
# the same identity chain they'd see from a web request.
#
# This controller deliberately does NOT inherit from ApplicationController,
# which would force Devise authentication. We're token-authenticated, not
# session-authenticated, and the user identity comes from the token's
# resource_owner_id.
class Mcp::ServerController < ActionController::Base
  # API endpoint authenticated by Bearer token, not session — CSRF
  # protection would 422 every POST before Doorkeeper sees the token
  # and decides whether to 401.
  skip_forgery_protection

  before_action :doorkeeper_authorize!
  before_action :set_tenant_from_token

  # Override Doorkeeper's default 401 response so the WWW-Authenticate
  # header points MCP clients at our OAuth discovery doc (RFC 9728). Without
  # this an unauth'd client gets `WWW-Authenticate: Bearer realm="..."`
  # which tells them nothing about WHERE to authenticate. Claude Code (and
  # MCP clients in general) follow the `resource_metadata=` pointer to
  # discover the auth server, kick off PKCE, and dynamically register
  # themselves — all without any manual config in .mcp.json beyond `url`.
  def doorkeeper_render_error_with(error)
    headers.merge!(error.headers)
    headers["WWW-Authenticate"] = www_authenticate_header
    render json: error.body, status: error.status
  end

  private

  def www_authenticate_header
    resource_metadata = url_for(
      controller: "mcp/well_known",
      action: "oauth_protected_resource",
      only_path: false,
      host: request.host_with_port,
      protocol: request.protocol
    )
    %(Bearer realm="MCP", resource_metadata="#{resource_metadata}")
  end

  public

  # POST /mcp
  def create
    payload = JSON.parse(request.body.read)
    context = authorization_context
    return render_token_error(:user_missing) if context.nil?

    response_body = AuditMetadata.with(
      acting_via: :mcp,
      client_application_id: doorkeeper_token.application_id
    ) do
      Mcp::RequestHandler.new(
        context: context,
        scopes: doorkeeper_token.scopes,
        client_application_id: doorkeeper_token.application_id,
        base_url: request.base_url
      ).call(payload)
    end
    render json: response_body
  rescue JSON::ParserError => e
    render json: parse_error(e), status: :bad_request
  end

  private

  # Pulls the User off the access token, builds a per-request
  # AuthorizationContext. The TenantUser link is the same row the web
  # session would resolve; the Person follows from that.
  #
  # If the user has been deleted since the token was issued, returns nil
  # so `set_tenant_from_token` can surface an auth failure instead of
  # raising RecordNotFound (which would 500 the request).
  def authorization_context
    user = User.find_by(id: doorkeeper_token.resource_owner_id)
    return nil if user.nil?

    tenant_user = ActsAsTenant.without_tenant do
      TenantUser.find_by(user_id: user.id, tenant_id: doorkeeper_token.tenant_id)
    end

    AuthorizationContext.new(
      user: user,
      tenant_user: tenant_user,
      person: tenant_user&.person
    )
  end

  # Token's tenant_id was bound at consent time; set it on the request
  # thread so any ActiveRecord query inside an Operation respects
  # acts_as_tenant scoping. Also asserts the user STILL has a TenantUser
  # membership in that tenant — if they were removed since the token was
  # issued, the token is effectively dead and we fail closed instead of
  # processing operations against an empty AuthorizationContext.
  def set_tenant_from_token
    tenant = Tenant.find_by(id: doorkeeper_token.tenant_id)
    return render_token_error(:tenant_missing) if tenant.nil?

    membership = ActsAsTenant.without_tenant do
      TenantUser.exists?(
        user_id: doorkeeper_token.resource_owner_id,
        tenant_id: tenant.id
      )
    end
    return render_token_error(:membership_revoked) unless membership

    ActsAsTenant.current_tenant = tenant
  end

  def render_token_error(reason)
    render json: {
      jsonrpc: "2.0", id: nil,
      error: { code: -32603, message: "token error: #{reason}" }
    }, status: :unauthorized
  end

  def parse_error(exception)
    {
      jsonrpc: "2.0", id: nil,
      error: { code: -32700, message: "parse error: #{exception.message}" }
    }
  end
end
