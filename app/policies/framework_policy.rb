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

  # Post to a suggestion's discussion thread — the same bar as submitting a
  # suggestion (any collaborator with suggest rights, or a tenant admin).
  # Commenting isn't approving, so no review-tier gating applies.
  #
  # @return [Boolean]
  def comment_on_suggestion? = tenant_admin? || framework_collaborator_can_suggest?

  # Publish the current draft as a new framework version. Restricted to
  # tenant admins and collaborators with publish rights (owner / editor) —
  # publishing fires cross-stream assessment migrations, rebuilds the
  # published projection, and rolls open assessment cycles, so it is a
  # narrower bar than editing or suggesting.
  #
  # @return [Boolean]
  def publish? = tenant_admin? || framework_collaborator_can_publish?

  # Define / edit a capability migration mapping for the current draft.
  # Same bar as publishing: the owner / editor validates (and may override)
  # the as-we-go mapping choices at the publish gate.
  #
  # @return [Boolean]
  def define_migration_mapping? = publish?

  # Direct structural edits to the framework (archive a capability, etc.).
  # Edit-rights bar — owner/editor/leads or tenant admin — distinct from the
  # broader suggest bar (#edit?) and the narrower publish bar (#publish?).
  #
  # @return [Boolean]
  def edit_structure? = tenant_admin? || framework_collaborator_can_edit?

  # @return [Boolean]
  def archive_capability? = edit_structure?

  # @return [Boolean]
  def add_capability? = edit_structure?

  # @return [Boolean]
  def add_category? = edit_structure?

  # @return [Boolean]
  def archive_category? = edit_structure?

  # Org-structure editorial edits — rename a role family / role / level (and,
  # via the Operation/MCP, a role's code/track or a level's code). Direct,
  # shape-preserving edits on the edit-rights bar, like the other structural
  # mutations — distinct from the suggested-edit path that capability / category
  # *text* uses.
  #
  # @return [Boolean]
  def update_role_family? = edit_structure?

  # @return [Boolean]
  def update_role? = edit_structure?

  # @return [Boolean]
  def update_level? = edit_structure?

  # Org-structure adds — new role family / role. Shape-preserving (a family or
  # role without published levels changes no rating grid; it renders as a ghost
  # until publish), on the same edit-rights bar as the other structural adds.
  #
  # @return [Boolean]
  def add_role_family? = edit_structure?

  # @return [Boolean]
  def add_role? = edit_structure?

  # Add a level to a role — shape-changing (new rating rows), draft-gated in
  # the aggregate, same edit-rights bar.
  #
  # @return [Boolean]
  def add_level? = edit_structure?

  # Edit a capability-role binding's weight / individual tolerance.
  # Shape-preserving (applies live) but still a structural edit, so it sits
  # on the edit-rights bar like the other binding/structure mutations.
  #
  # @return [Boolean]
  def update_binding? = edit_structure?

  # Bind a capability to a role (re-scope it). Shape-changing — auto-opens a
  # draft — but on the same edit-rights bar as the other structural edits.
  #
  # @return [Boolean]
  def add_binding? = edit_structure?

  # Remove a capability-role binding (un-scope it from a role). Shape-changing,
  # edit-rights bar.
  #
  # @return [Boolean]
  def remove_binding? = edit_structure?

  # Reorder the illustrations for one expectation × role. Display-order only
  # (shape-preserving, applies live) — a direct structural edit, not the
  # suggest path, so it sits on the edit-rights bar.
  #
  # @return [Boolean]
  def reorder_illustrations? = edit_structure?

  # Reorder the framework's capability categories (display order only,
  # shape-preserving). Same edit-rights bar.
  #
  # @return [Boolean]
  def reorder_categories? = edit_structure?

  # Reorder the capabilities within a category (display order only,
  # shape-preserving). Same edit-rights bar.
  #
  # @return [Boolean]
  def reorder_capabilities? = edit_structure?

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

  # Rename the framework. Deliberately the SAME bar as #manage_collaborators?
  # — tenant admins and framework **owners** — because the name is the
  # framework's identity across every surface (index, cycles, assessments,
  # MCP), not content an editor or lead curates. Delegated, not restated, so
  # the two can't drift.
  #
  # @return [Boolean]
  def rename? = manage_collaborators?

  private

  # Checks whether the current person holds a collaborator role that grants
  # edit rights on this framework.
  #
  # @return [Boolean]
  def framework_collaborator_can_edit?
    return false unless person.present?

    collaborator_roles.can_edit?
  end

  # Checks whether the current person holds any non-viewer collaborator role
  # on this framework (can propose suggestions).
  #
  # @return [Boolean]
  def framework_collaborator_can_suggest?
    return false unless person.present?

    can_suggest?
  end

  # Checks whether the current person holds a collaborator role that grants
  # publish rights (owner / editor) on this framework.
  #
  # @return [Boolean]
  def framework_collaborator_can_publish?
    return false unless person.present?

    can_publish?
  end
end
