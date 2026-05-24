# frozen_string_literal: true

# OAuth discovery endpoints required by MCP clients that auto-discover
# the auth server from the protected resource. Without these, a client
# hits /mcp, gets 401, follows the WWW-Authenticate `resource_metadata`
# pointer here, then to the authorization-server metadata, and is able
# to complete OAuth + dynamic client registration without any manual
# config beyond the bare `url` in .mcp.json.
#
#   - GET /.well-known/oauth-protected-resource   (RFC 9728)
#   - GET /.well-known/oauth-authorization-server (RFC 8414)
#
# Both endpoints are unauthenticated — they're public discovery docs.
class Mcp::WellKnownController < ActionController::Base
  # GET /.well-known/oauth-protected-resource
  def oauth_protected_resource
    render json: {
      resource: issuer,
      authorization_servers: [ issuer ],
      scopes_supported: %w[read write],
      bearer_methods_supported: [ "header" ],
      resource_documentation: "#{issuer}/mcp"
    }
  end

  # GET /.well-known/oauth-authorization-server
  def oauth_authorization_server
    render json: {
      issuer: issuer,
      authorization_endpoint:           "#{issuer}/oauth/authorize",
      token_endpoint:                   "#{issuer}/oauth/token",
      revocation_endpoint:              "#{issuer}/oauth/revoke",
      registration_endpoint:            "#{issuer}/oauth/register",
      response_types_supported:         [ "code" ],
      grant_types_supported:            [ "authorization_code" ],
      code_challenge_methods_supported: [ "S256" ],
      scopes_supported:                 %w[read write],
      token_endpoint_auth_methods_supported: [ "none" ]
    }
  end

  private

  def issuer
    request.base_url
  end
end
