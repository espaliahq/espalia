# frozen_string_literal: true

# Authorizes the tenant user management surface.
#
# Only tenant administrators (TenantUser#admin?) and global admins
# (User#global_admin?) can list members, view a member's detail,
# change their tenant role, or manage their framework collaborator
# assignments from the tenant-wide screen.
#
class TenantUserPolicy < ApplicationPolicy
  def index? = tenant_admin?
  def show? = tenant_admin?
  def update? = tenant_admin?
  def manage_collaborators? = tenant_admin?
  def collaborator_scope_picker? = tenant_admin?
end
