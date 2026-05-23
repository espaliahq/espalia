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
  before_action :doorkeeper_authorize!
  before_action :set_tenant_from_token

  # POST /mcp
  def create
    payload = JSON.parse(request.body.read)
    response_body = Mcp::RequestHandler.new(context: authorization_context).call(payload)
    render json: response_body
  rescue JSON::ParserError => e
    render json: parse_error(e), status: :bad_request
  end

  private

  # Pulls the User off the access token, builds a per-request
  # AuthorizationContext. The TenantUser link is the same row the web
  # session would resolve; the Person follows from that.
  def authorization_context
    user = User.find(doorkeeper_token.resource_owner_id)
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
  # acts_as_tenant scoping.
  def set_tenant_from_token
    tenant = Tenant.find_by(id: doorkeeper_token.tenant_id)
    return render_token_error(:tenant_missing) if tenant.nil?

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
