# frozen_string_literal: true

# OAuth 2.0 Dynamic Client Registration (RFC 7591) — minimal subset.
#
# MCP clients (Claude Code, Claude Desktop, etc.) POST a JSON body
# describing themselves and get back a client_id. They then proceed
# through the authorization-code + PKCE flow with that id. Without
# this endpoint a human would have to manually create an Mcp::Application
# in the admin UI for every install, paste the client_id into config,
# etc — the UX would be brutal and nobody would use it.
#
# Scope / safety:
#   - PUBLIC endpoint (no auth) — that's how DCR works.
#   - Issues public clients only: no client_secret, PKCE-mandatory.
#   - Skips CSRF (request is JSON, not a form), and skips Devise
#     authentication (inherits ActionController::API for both).
#   - No DCR management endpoints (no GET/PUT/DELETE on registered
#     clients) — V1 keeps the surface tight.
class Mcp::ClientRegistrationsController < ActionController::API
  # POST /oauth/register
  def create
    name = (params[:client_name].presence || "MCP Client")
    redirect_uris = Array(params[:redirect_uris]).select(&:present?)

    if redirect_uris.empty?
      render json: { error: "invalid_redirect_uri", error_description: "at least one redirect_uri is required" },
        status: :bad_request
      return
    end

    application = Mcp::Application.new(
      name: name,
      redirect_uri: redirect_uris.join("\n"),
      scopes: requested_scopes,
      confidential: false,
      # Marks this row as a DCR registration so Mcp::PruneStaleClientsJob
      # can clean it up if it goes unused. Admin-registered apps stay nil
      # and are never auto-pruned.
      dynamically_registered_at: Time.current
    )

    if application.save
      render json: registration_response(application, redirect_uris), status: :created
    else
      render json: {
        error: "invalid_client_metadata",
        error_description: application.errors.full_messages.join(", ")
      }, status: :bad_request
    end
  end

  private

  # Constrain to the scopes our Doorkeeper config recognises. A client
  # asking for a scope we don't expose is silently downgraded to the
  # safe default rather than producing a half-broken registration.
  def requested_scopes
    asked = (params[:scope].to_s.presence || "read").split(/\s+/)
    known = Doorkeeper.config.scopes.to_a.map(&:to_s)
    (asked & known).presence&.join(" ") || "read"
  end

  def registration_response(application, redirect_uris)
    {
      client_id: application.uid,
      client_name: application.name,
      redirect_uris: redirect_uris,
      grant_types: [ "authorization_code" ],
      response_types: [ "code" ],
      token_endpoint_auth_method: "none",
      scope: application.scopes.to_s,
      client_id_issued_at: application.created_at.to_i
    }
  end
end
