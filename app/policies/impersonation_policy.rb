# frozen_string_literal: true

# Authorizes a tenant admin to impersonate ("view as") another user.
#
# The +record+ is the target {TenantUser} whose perspective the acting
# admin wants to assume. Impersonation is read-only and confined to the
# acting admin's current tenant.
#
# The single rule that matters most: an impersonator must never gain MORE
# privilege than they already hold. That is enforced by refusing to target
# global admins or other tenant admins — so a tenant admin can only ever
# step "down" into a non-admin member's view, never sideways or up.
#
# This policy is always evaluated against the REAL admin's identity chain
# (never the impersonated one) and is re-checked on every request, so a
# revoked admin role or a target that becomes an admin ends the session
# mid-flight (see Impersonatable#resolve_impersonated_tenant_user).
#
class ImpersonationPolicy < ApplicationPolicy
  # @return [Boolean] whether the acting admin may impersonate the target
  def create?
    return false unless tenant_admin?
    return false if record.blank?
    return false if targeting_self?
    return false if record.user&.global_admin? # no privilege escalation
    return false if record.admin?              # non-admins only
    return false unless same_tenant?

    true
  end

  private

  # True when the target membership belongs to the same User as the acting
  # admin — you cannot impersonate yourself.
  def targeting_self?
    user.present? && record.user_id == user.id
  end

  # The target must live in the acting admin's active tenant. A tenant admin
  # carries a tenant_user; a global admin may have none, so fall back to the
  # ambient tenant.
  def same_tenant?
    active_tenant_id = tenant_user&.tenant_id || ActsAsTenant.current_tenant&.id
    active_tenant_id.present? && record.tenant_id == active_tenant_id
  end
end
