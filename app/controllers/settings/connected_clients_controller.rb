# frozen_string_literal: true

# User-facing list of MCP clients connected to their account, with the
# ability to revoke any active token. One row per (application, tenant)
# token; revoking a token is irreversible from the user's perspective —
# the MCP client will have to re-authorise to keep working.
class Settings::ConnectedClientsController < ApplicationController
  before_action :authenticate_user!

  # GET /settings/connected_clients
  def index
    tokens = ActsAsTenant.without_tenant do
      Mcp::AccessToken
        .where(resource_owner_id: current_user.id, revoked_at: nil)
        .order(created_at: :desc)
        .includes(:application)
        .to_a
    end

    render Views::Settings::ConnectedClients::IndexView.new(
      tokens: tokens,
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
      redirect_to settings_connected_clients_path, alert: "Token not found.", status: :see_other
      return
    end

    token.revoke
    # FK guards against a missing application row, but a safe-nav fallback
    # avoids surfacing a NoMethodError to the user if data ever diverges.
    client_name = token.application&.name || "the client"
    redirect_to settings_connected_clients_path,
      notice: "Revoked access for #{client_name}. The client must re-authorise to keep working.",
      status: :see_other
  end
end
