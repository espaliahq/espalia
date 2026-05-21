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

  # Edit-mode access for the Framework Explorer: same bar as submitting a
  # suggestion — any collaborator role plus tenant admin. Viewers get 404.
  #
  # @return [Boolean]
  def edit? = tenant_admin? || framework_collaborator_can_suggest?

  # @return [Boolean]
  def edit_matrix? = edit?

  # @return [Boolean]
  def suggest_edit? = tenant_admin? || framework_collaborator_can_suggest?

  # Non-viewer collaborators can submit create/delete suggestions. Approval
  # gating happens later in FrameworkSuggestionPolicy#approve?.
  #
  # @return [Boolean]
  def submit_suggestion? = tenant_admin? || framework_collaborator_can_suggest?

  # @return [Boolean]
  def view_suggestions? = tenant_admin? || framework_collaborator_can_suggest?

  # Convenience method for views to conditionally render admin UI.
  #
  # @return [Boolean]
  def admin? = tenant_admin?

  # Manage framework collaborator assignments (add/remove).
  # Open to tenant admins and to framework owners — the latter so a person
  # who owns a framework can curate its collaborators without needing
  # tenant-wide admin rights.
  #
  # @return [Boolean]
  def manage_collaborators?
    tenant_admin? || (person.present? && can_manage_collaborators?)
  end

  private

  # Checks whether the current person holds a collaborator role that grants
  # edit rights on this framework.
  #
  # @return [Boolean]
  def framework_collaborator_can_edit?
    return false unless person.present?

    collaborator_roles.with_edit_rights.exists?
  end

  # Checks whether the current person holds any non-viewer collaborator role
  # on this framework (can propose suggestions).
  #
  # @return [Boolean]
  def framework_collaborator_can_suggest?
    return false unless person.present?

    can_suggest?
  end
end
