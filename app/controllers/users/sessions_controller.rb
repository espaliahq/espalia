# frozen_string_literal: true

# Overrides Devise's SessionsController to render the sign-in page using Phlex.
#
# A tenant sign-on URL (`/t/:tenant_slug/sign-in`, #660) renders the same page
# under the tenant's name and theme, and a login from it lands scoped to that
# tenant. The slug rides the form as a hidden field so the POST (and a failed
# attempt, via Users::FailureApp) keeps the tenant context.
class Users::SessionsController < Devise::SessionsController
  # GET /users/sign_in
  # GET /t/:tenant_slug/sign-in
  def new
    if params[:tenant_slug].present? && sign_in_tenant.nil?
      return redirect_to new_user_session_path
    end

    @theme_tenant = sign_in_tenant
    self.resource = resource_class.new
    render Views::Users::Sessions::NewView.new(
      resource: resource, flash: flash,
      google_sso: Rails.configuration.x.google_sso_available,
      tenant: sign_in_tenant
    )
  end

  # POST /users/sign_in
  def create
    super do |user|
      scope_session_to_sign_in_tenant(user)
    end
  end

  private

  # @return [Tenant, nil] the tenant whose sign-on URL (or form) this request came through
  def sign_in_tenant
    return @sign_in_tenant if defined?(@sign_in_tenant)

    slug = params[:tenant_slug].presence
    @sign_in_tenant = slug.is_a?(String) ? Tenant.find_by(slug: slug) : nil
  end

  # The sign-on URL promises the tenant's workspace, so the session starts
  # there — but only for a member; anyone else gets the usual resolution.
  def scope_session_to_sign_in_tenant(user)
    tenant = sign_in_tenant
    return unless tenant

    member = ActsAsTenant.without_tenant { user.tenants.exists?(tenant.id) }
    session[:current_tenant_id] = tenant.id if member
  end
end
