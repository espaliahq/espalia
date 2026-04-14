# frozen_string_literal: true

# Authorization policy for framework resources.
#
# Tenant members can view; tenant admins and framework collaborators
# with edit rights can modify. Collaborator-based permissions activate
# once the framework_collaborators table is populated.
#
class FrameworkPolicy < ApplicationPolicy
  include FrameworkCollaboratorPermissions

  # @return [Boolean]
  def index?  = tenant_member?

  # @return [Boolean]
  def show?   = tenant_member?

  # @return [Boolean]
  def matrix? = tenant_member?

  # @return [Boolean]
  def settings? = tenant_admin?

  # @return [Boolean]
  def update_settings? = tenant_admin?

  # @return [Boolean]
  def create_illustration? = tenant_admin? || framework_collaborator_can_edit?

  # @return [Boolean]
  def update_illustration? = tenant_admin? || framework_collaborator_can_edit?

  # @return [Boolean]
  def suggest_edit? = tenant_member?

  # Any tenant member can submit a create/delete suggestion. Approval gating
  # happens later in FrameworkSuggestionPolicy#approve?.
  #
  # @return [Boolean]
  def submit_suggestion? = tenant_member?

  # @return [Boolean]
  def view_suggestions? = tenant_member?

  # Convenience method for views to conditionally render admin UI.
  #
  # @return [Boolean]
  def admin? = tenant_admin?

  private

  # Checks whether the current person holds a collaborator role that grants
  # edit rights on this framework.
  #
  # @return [Boolean]
  def framework_collaborator_can_edit?
    return false unless person.present?

    collaborator_roles.with_edit_rights.exists?
  end
end
