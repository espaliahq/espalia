# frozen_string_literal: true

# Starts and stops a tenant admin's "view as another user" session.
#
# Impersonation overrides only the TenantUser/Person tiers of the identity
# chain (see {Impersonatable}); the Devise session stays the real admin's.
# It is read-only and confined to the admin's current tenant.
#
# Authorisation is always evaluated against {Impersonatable#real_context} —
# the real admin's identity — not `pundit_user`, which by the time this
# action runs may already be the impersonated (member) context. That also
# lets an admin re-target without stopping first.
class ImpersonationsController < ApplicationController
  # POST /impersonation
  def create
    target = TenantUser.find(params.expect(:tenant_user_id))

    unless ImpersonationPolicy.new(real_context, target).create?
      raise Pundit::NotAuthorizedError
    end

    session[Impersonatable::SESSION_KEY] = {
      "tenant_user_id" => target.id,
      "expires_at" => (Time.current + Impersonatable::TTL).iso8601
    }
    redirect_to root_path, status: :see_other, notice: "Now viewing as #{target_display_name(target)}."
  rescue ActiveRecord::RecordNotFound
    redirect_to tenant_users_path, alert: "That user could not be found.", status: :see_other
  end

  # DELETE /impersonation
  def destroy
    clear_impersonation!
    redirect_to root_path, status: :see_other, notice: "Stopped impersonating."
  end

  private

  # @param tenant_user [TenantUser]
  # @return [String]
  def target_display_name(tenant_user)
    tenant_user.person&.name.presence || TenantUser.derive_person_name(tenant_user.user.email)
  end
end
