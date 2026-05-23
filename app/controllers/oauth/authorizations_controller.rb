# frozen_string_literal: true

# Custom OAuth authorization controller. Inserts a tenant picker into the
# consent flow so the resulting access token is bound to exactly one
# tenant (the MCP server can't ambiguate when the user belongs to many).
#
# The submitted `tenant_id` rides on the form POST to /oauth/authorize.
# Doorkeeper's PreAuthorization slices it from the request params via
# `custom_access_token_attributes [:tenant_id]` (see the initializer),
# AuthorizationCode persists it on the AccessGrant, and the grant→token
# exchange copies it onto the AccessToken automatically.
#
# Inherits Doorkeeper's #create and #destroy unchanged; only #new is
# overridden to render our Phlex consent view, and a small guard ensures
# the chosen tenant actually belongs to the signed-in user.
class Oauth::AuthorizationsController < Doorkeeper::AuthorizationsController
  def new
    render_consent_screen
  end

  def create
    return render_consent_screen(error: "Select a workspace you belong to.") unless tenant_valid?

    super
  end

  private

  # Renders the Phlex consent view. Kept private so #new and #create share
  # exactly one render path — any view-shape change happens once.
  # Calls `pre_auth.authorizable?` first so `pre_auth.client` is populated
  # (Doorkeeper's PreAuthorization lazily resolves the client inside
  # validation, not on construction); falls back to render_error if the
  # OAuth params themselves are invalid.
  def render_consent_screen(error: nil)
    return render_error unless pre_auth.authorizable?

    if skip_authorization? || can_authorize_response?
      redirect_or_render(authorize_response)
      return
    end

    render(
      Views::Oauth::AuthorizationsView.new(
        pre_auth: pre_auth,
        application: pre_auth.client.application,
        tenants: current_user_tenants,
        selected_tenant_id: params[:tenant_id],
        error: error
      ),
      status: (error ? :unprocessable_content : :ok)
    )
  end

  # The user picks any tenant they belong to — not just the one
  # ApplicationController happened to seed into session[:current_tenant_id].
  # Bypass acts_as_tenant scoping here so the dropdown shows all of them
  # (the join table is tenant-scoped and would otherwise filter to just the
  # active one).
  def current_user_tenants
    ActsAsTenant.without_tenant { current_resource_owner.tenants.order(:name).to_a }
  end

  def tenant_valid?
    tenant_id = params[:tenant_id]
    return false if tenant_id.blank?

    ActsAsTenant.without_tenant do
      current_resource_owner.tenants.exists?(id: tenant_id)
    end
  end
end
