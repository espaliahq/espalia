# frozen_string_literal: true

# Authorizes tenant-administration surfaces — the admin dashboard at
# /tenant and the theme editor at /tenant/theme. Tenant members are
# denied; only tenant administrators (TenantUser#admin?) and global
# admins (User#global_admin?) can view or update.
#
class TenantPolicy < ApplicationPolicy
  def show? = tenant_admin?
  def update_theme? = tenant_admin?
end
