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
# Both endpoints are unauthenticated public discovery documents — the
# specs require them to be reachable without any credentials so a fresh
# MCP client can self-configure. Pundit is intentionally bypassed; the
# only "authorization" is that the contents are non-sensitive metadata.
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

  # OAuth 2.0 issuer must be a STABLE long-lived identifier — RFC 8414 §2
  # and RFC 9207 require clients to do exact-match validation. Behind a
  # proxy / load balancer, `request.base_url` flips based on
  # X-Forwarded-Host / X-Forwarded-Proto and would silently break token
  # validation on any deploy with an LB in front. Prefer the configured
  # value; only fall back to `request.base_url` in development where the
  # canonical URL is the dev server itself.
  def issuer
    configured = Rails.application.config.x.oauth_issuer.presence
    return configured if configured

    # In production a proxy-derived issuer is dangerous: tokens are bound
    # to the issuer string at consent time, so any drift breaks every
    # subsequent client. Fail loud rather than hand out unstable metadata.
    if Rails.env.production?
      raise "OAUTH_ISSUER is not configured — set the env var to the canonical https URL"
    end

    request.base_url
  end
end
