class ApplicationController < ActionController::Base
  include Pundit::Authorization

  set_current_tenant_through_filter

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  before_action :authenticate_user!
  before_action :set_tenant

  rescue_from Pundit::NotAuthorizedError, with: :user_not_authorized

  private

  # Resolves the current user's TenantUser membership for the active tenant.
  # Cached per request. Returns nil if no membership exists.
  #
  # @return [TenantUser, nil]
  def current_tenant_user
    return @current_tenant_user if defined?(@current_tenant_user)
    tenant = ActsAsTenant.current_tenant
    @current_tenant_user = ActsAsTenant.without_tenant do
      current_user&.tenant_users&.find_by(tenant: tenant)
    end
  end

  # Resolves the Person domain entity for the current user in the active tenant.
  # Cached per request. Returns nil if no linked Person exists.
  #
  # @return [Person, nil]
  def current_person
    return @current_person if defined?(@current_person)
    @current_person = current_tenant_user&.person
  end

  helper_method :current_tenant_user, :current_person

  # Builds the Pundit authorization context carrying the full identity chain.
  #
  # @return [AuthorizationContext]
  def pundit_user
    AuthorizationContext.new(
      user: current_user,
      tenant_user: current_tenant_user,
      person: current_person
    )
  end

  # Handles Pundit authorization failures with a redirect and flash alert.
  #
  # @param _exception [Pundit::NotAuthorizedError]
  # @return [void]
  def user_not_authorized(_exception = nil)
    redirect_back fallback_location: root_path, alert: "You are not authorized to perform this action."
  end

  # Resolves the current tenant for the request.
  #
  # Tries the tenant stored in session first (set on login or via tenant switch).
  # Falls back to auto-setting when the user belongs to exactly one tenant.
  # Sets nothing for global admins with no tenant memberships.
  def set_tenant
    return unless current_user

    # Use without_tenant to bypass any existing scope — we are determining
    # which tenant to activate, so we must query unconditionally.
    tenant = ActsAsTenant.without_tenant do
      if session[:current_tenant_id]
        current_user.tenants.find_by(id: session[:current_tenant_id])
      else
        t = current_user.tenants.first
        if t
          session[:current_tenant_id] = t.id
          t
        end
      end
    end

    set_current_tenant(tenant) if tenant
  end

  # Directs users to the right place after sign-in based on tenant membership.
  #
  # Always auto-selects the first tenant. Multi-tenant users can switch
  # tenants via the user menu dropdown in the navbar.
  #
  # @param resource [User]
  # @return [String] redirect path
  def after_sign_in_path_for(resource)
    # Use without_tenant — no tenant is set yet at sign-in time.
    first_membership = ActsAsTenant.without_tenant { resource.tenant_users.first }
    session[:current_tenant_id] = first_membership.tenant_id if first_membership
    root_path
  end
end
