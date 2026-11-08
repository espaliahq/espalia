# frozen_string_literal: true

# Overrides Devise's SessionsController to render the sign-in page using Phlex.
#
# A tenant sign-on URL (`/t/:tenant_slug/sign-in` or a custom domain, #660)
# renders the same page under the tenant's name and theme, and a login from it
# lands scoped to that tenant. The slug rides the form as a hidden field, so a
# failed attempt — which Devise recalls into #new with the POST's params —
# re-renders the branded page too.
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

  private

  # Devise consults this after its yield, and ApplicationController's version
  # writes the user's FIRST tenant into the session — so the sign-on scoping
  # must run after super, or a multi-tenant member lands in the wrong tenant.
  def after_sign_in_path_for(resource)
    path = super
    scope_session_to_sign_in_tenant(resource)
    path
  end

  # @return [Tenant, nil] the tenant whose sign-on URL this request came
  #   through — {ApplicationController#sign_on_tenant} over the slug path or
  #   the form's hidden field
  def sign_in_tenant
    return @sign_in_tenant if defined?(@sign_in_tenant)

    @sign_in_tenant = sign_on_tenant(params[:tenant_slug])
  end

  # The sign-on URL promises the tenant's workspace, so the session starts
  # there — but only for a member; anyone else gets the usual resolution.
  def scope_session_to_sign_in_tenant(user)
    pin_session_to_tenant(user, sign_in_tenant)
  end
end
