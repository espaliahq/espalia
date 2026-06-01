# frozen_string_literal: true

# Tenant-admin impersonation ("view as another user").
#
# Lets a tenant admin experience the system from another user's
# perspective WITHOUT swapping the Devise session. The real admin stays
# {#current_user}; only the lower two tiers of the identity chain —
# TenantUser and Person — are overridden to the impersonated target. Every
# Pundit policy, every assessment/matrix view, and {ApplicationController#pundit_user}
# then render as the target sees them, with no downstream changes.
#
# Design (see the impersonation design discussion):
# - **Read-only.** Writes are blocked at the controller boundary
#   (#enforce_impersonation_read_only) and again in Operations::Base.
# - **Within-tenant, non-admin targets only.** Enforced by
#   {ImpersonationPolicy}, re-checked on EVERY request so a revoked admin
#   role or a target promoted to admin ends the session immediately —
#   failing closed back to the real admin's own view.
# - **Auto-expiry.** A hard {TTL} cap (no refresh-on-activity); also
#   cleared on tenant switch and (via Devise resetting the session) sign-out.
#
# The acting admin's authority is ALWAYS evaluated against {#real_context},
# never the impersonated context — otherwise an active impersonation (a
# member's view) could never re-target or be re-authorised.
module Impersonatable
  extend ActiveSupport::Concern

  # Session slot holding the impersonation handle: the target TenantUser id
  # (pins it to this tenant's membership) plus a hard expiry timestamp.
  SESSION_KEY = "impersonation"

  # Hard cap on a single impersonation session. Not refreshed on activity —
  # simpler and safer than a sliding window.
  TTL = 30.minutes

  included do
    helper_method :impersonating?, :impersonated_display_name
  end

  # The acting admin's own membership — never the impersonated target.
  # Mirrors the lookup ApplicationController used before impersonation
  # existed, including best-effort Person auto-linking.
  #
  # @return [TenantUser, nil]
  def real_tenant_user
    return @real_tenant_user if defined?(@real_tenant_user)

    tenant = ActsAsTenant.current_tenant
    @real_tenant_user = ActsAsTenant.without_tenant do
      tu = current_user&.tenant_users&.find_by(tenant: tenant)
      begin
        auto_link_person(tu) if tu&.person_id.nil?
      rescue StandardError => e
        Rails.logger.warn("auto_link_person failed for TenantUser #{tu&.id}: #{e.class}: #{e.message}")
      end
      tu
    end
  end

  # The membership the rest of the request should act as: the impersonated
  # target when a valid session is active, otherwise the real admin.
  #
  # @return [TenantUser, nil]
  def effective_tenant_user
    impersonated_tenant_user || real_tenant_user
  end

  # The User whose privileges Pundit and views should act with: the
  # impersonated target's user while impersonating, otherwise the real admin.
  #
  # {#current_user} (the Devise session) stays the real admin for audit and the
  # impersonation guard ({#real_context}); only the authorization context
  # renders as the target. Without this, a *global admin* impersonating a
  # member would keep `global_admin?` (and every admin-gated policy) — the
  # target's reduced tenant role can't override that flag.
  #
  # @return [User, nil]
  def effective_user
    impersonated_tenant_user&.user || current_user
  end

  # The impersonated target, or nil. Resolution validates the session
  # (expiry + {ImpersonationPolicy} against the real admin) and clears it on
  # any failure, so this is the single source of truth for "is impersonation
  # currently active".
  #
  # @return [TenantUser, nil]
  def impersonated_tenant_user
    return @impersonated_tenant_user if defined?(@impersonated_tenant_user)

    @impersonated_tenant_user = resolve_impersonated_tenant_user
  end

  # @return [Boolean] whether a valid impersonation session is active.
  def impersonating?
    impersonated_tenant_user.present?
  end

  # @return [String, nil] human-readable name of the impersonated target.
  def impersonated_display_name
    tu = impersonated_tenant_user
    return nil unless tu

    tu.person&.name.presence || TenantUser.derive_person_name(tu.user.email)
  end

  # The acting admin's identity chain, independent of any impersonation.
  # Used to authorise the act of impersonation itself.
  #
  # @return [AuthorizationContext]
  def real_context
    AuthorizationContext.new(
      user: current_user,
      tenant_user: real_tenant_user,
      person: real_tenant_user&.person
    )
  end

  # Drops the impersonation session and forgets the memoised target so the
  # rest of the request reverts to the real admin.
  #
  # @return [void]
  def clear_impersonation!
    session.delete(SESSION_KEY)
    remove_instance_variable(:@impersonated_tenant_user) if defined?(@impersonated_tenant_user)
  end

  # before_action: blocks state-changing requests while impersonating.
  # Safe (GET/HEAD) requests pass; the impersonation and tenant-switch
  # controllers and all Devise flows are exempt so the user can always
  # stop impersonating, switch tenant, or sign out.
  #
  # A Turbo Frame `src`/form request can't follow a redirect (Turbo looks
  # for the frame in the redirect target, doesn't find it, and leaves the
  # section broken), so for frame requests we degrade into the same
  # in-frame recovery message {ApplicationController#user_not_authorized}
  # uses for denials; everything else redirects back with a flash.
  #
  # @return [void]
  def enforce_impersonation_read_only
    return unless impersonating?
    return if request.get? || request.head?
    return if impersonation_exempt_controller?

    message = "You're viewing as #{impersonated_display_name} — that action is read-only. " \
              "Stop impersonating to make changes."
    if turbo_frame_request?
      render_turbo_frame_recovery(message)
    else
      redirect_back fallback_location: root_path, alert: message
    end
  end

  private

  # @return [TenantUser, nil]
  def resolve_impersonated_tenant_user
    data = session[SESSION_KEY]
    return nil if data.blank?
    return clear_and_return_nil if impersonation_expired?(data)

    target = ActsAsTenant.without_tenant { TenantUser.find_by(id: data["tenant_user_id"]) }

    # Re-authorise every request against the REAL admin: a revoked admin
    # role, a target promoted to admin, or a tenant switch all fail closed.
    unless target &&
           target.tenant_id == ActsAsTenant.current_tenant&.id &&
           ImpersonationPolicy.new(real_context, target).create?
      return clear_and_return_nil
    end

    target
  end

  def clear_and_return_nil
    session.delete(SESSION_KEY)
    nil
  end

  # @param data [Hash] the session handle
  # @return [Boolean]
  def impersonation_expired?(data)
    expires_at = data["expires_at"]
    return true if expires_at.blank?

    Time.iso8601(expires_at.to_s) <= Time.current
  rescue ArgumentError
    true
  end

  # @return [Boolean] controllers exempt from the read-only write block.
  def impersonation_exempt_controller?
    devise_controller? ||
      controller_path == "impersonations" ||
      controller_path == "users/tenant_switches"
  end
end
