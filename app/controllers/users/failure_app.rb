# frozen_string_literal: true

# Sends a failed sign-in attempt back to the tenant sign-on page it came from
# (#660). The branded form carries its tenant's slug as a hidden field, so a
# wrong password returns to the branded page instead of the generic one.
class Users::FailureApp < Devise::FailureApp
  def redirect_url
    slug = request.params["tenant_slug"]
    return super unless slug.is_a?(String) && slug.present?

    tenant_sign_in_path(tenant_slug: slug)
  end
end
