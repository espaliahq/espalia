# frozen_string_literal: true

# User-facing list of MCP clients connected to their account, with the
# ability to revoke any active token. One row per (application, tenant)
# token; revoking a token is irreversible from the user's perspective —
# the MCP client will have to re-authorise to keep working.
class Settings::ConnectedClientsController < ApplicationController
  before_action :authenticate_user!

  # GET /settings/connected_clients
  def index
    authorize Mcp::AccessToken

    tokens = ActsAsTenant.without_tenant do
      Mcp::AccessToken
        .where(resource_owner_id: current_user.id, revoked_at: nil)
        .order(created_at: :desc)
        .includes(:application)
        .to_a
    end

    # Pre-resolve tenants once so the view can render workspace names
    # without an N+1 (`Tenant.unscoped.find_by(id: ...)` per token).
    tenant_map = ActsAsTenant.without_tenant do
      Tenant.where(id: tokens.map(&:tenant_id).uniq).index_by(&:id)
    end

    render Views::Settings::ConnectedClients::IndexView.new(
      tokens: tokens,
      tenant_map: tenant_map,
      mcp_url: mcp_endpoint_url,
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: current_user.tenants
    )
  end

  # DELETE /settings/connected_clients/:id
  def destroy
    token = ActsAsTenant.without_tenant do
      Mcp::AccessToken.find_by(id: params[:id], resource_owner_id: current_user.id)
    end

    if token.nil?
      # Skip authorize on the not-found path — there is no record to
      # authorize against and the `resource_owner_id` filter above is
      # the scoping that prevents revoking someone else's token.
      redirect_to settings_connected_clients_path, alert: "Token not found.", status: :see_other
      return
    end

    authorize token

    token.revoke
    # FK guards against a missing application row, but a safe-nav fallback
    # avoids surfacing a NoMethodError to the user if data ever diverges.
    client_name = token.application&.name || "the client"
    redirect_to settings_connected_clients_path,
      notice: "Revoked access for #{client_name}. The client must re-authorise to keep working.",
      status: :see_other
  end

  private

  # The Streamable-HTTP MCP endpoint a client connects to. Built from the
  # configured OAuth issuer so the displayed URL matches the issuer that
  # tokens are bound to — mirrors Mcp::WellKnownController#issuer. Falls
  # back to the request's base URL in non-production where the dev server
  # IS the canonical host.
  #
  # @return [String] absolute https URL ending in `/mcp`
  def mcp_endpoint_url
    issuer = Rails.application.config.x.oauth_issuer.presence || request.base_url
    "#{issuer}/mcp"
  end
end
