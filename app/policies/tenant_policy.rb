# frozen_string_literal: true

# Authorizes tenant-administration surfaces — the admin dashboard at
# /tenant and the theme editor at /tenant/theme. Tenant members are
# denied; only tenant administrators (TenantUser#admin?) and global
# admins (User#global_admin?) can view or update.
#
class TenantPolicy < ApplicationPolicy
  # @return [Boolean] whether the viewer can see the tenant admin hub
  def show? = tenant_admin?

  # @return [Boolean] whether the viewer can edit the tenant theme
  def update_theme? = tenant_admin?

  # @return [Boolean] whether the viewer can rename the performance states
  #   for this tenant (display labels only — scoring policy lives on the
  #   framework and has its own bar)
  def update_scoring_vocabulary? = tenant_admin?
end
