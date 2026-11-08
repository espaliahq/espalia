# frozen_string_literal: true

# Handles OmniAuth callbacks for external identity providers (Google).
#
# The provisioning rules — verified-email gate, link-by-email, auto-create
# from a matching Person — live on User.from_google_omniauth. This controller
# only translates the result into a session + flash.
class Users::OmniauthCallbacksController < Devise::OmniauthCallbacksController
  REFUSAL_FLASH = {
    email_unverified: "Your Google account email isn't verified. Verify it with Google and try again.",
    no_matching_account: "No #{Rails.application.config.x.product_name} account is linked to this Google address. Ask your admin to invite you.",
    invalid_payload: "We couldn't read the response from Google. Please try again."
  }.freeze

  # GET /users/auth/google_oauth2/callback
  def google_oauth2
    user, reason = User.from_google_omniauth(request.env["omniauth.auth"])

    if user&.persisted?
      sign_in_and_redirect user, event: :authentication
      set_flash_message(:notice, :success, kind: "Google") if is_navigational_format?
    else
      flash[:alert] = REFUSAL_FLASH.fetch(reason, REFUSAL_FLASH[:invalid_payload])
      redirect_to new_user_session_path
    end
  end

  # Devise calls this on OmniAuth strategy errors (denied consent, network, etc.).
  def failure
    redirect_to new_user_session_path, alert: failure_message
  end

  private

  # A Google sign-in that started on a tenant sign-on page carries the slug
  # in omniauth.params (#660); the shared resolution also covers the custom
  # domain the callback arrived on and the instance's default tenant, so SSO
  # and password sign-ins land in the same place. Runs after super, which
  # writes the user's first membership — same ordering as the password flow.
  def after_sign_in_path_for(resource)
    path = super
    pin_session_to_tenant(resource, sign_on_tenant(request.env.dig("omniauth.params", "tenant_slug")))
    path
  end
end
