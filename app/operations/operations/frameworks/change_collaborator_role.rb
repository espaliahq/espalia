# frozen_string_literal: true

# Changes a collaborator's **framework-wide** role — e.g. promote a viewer to
# editor. Permission-changing → :in_app approval.
#
# Framework-wide is the whole surface, not a restriction bolted on. The scope
# pair stays fixed across the change (the aggregate keys the old and new
# assignment on the same scope), so both roles must share a scope shape — and
# every scoped lead role has its OWN entity type, so two DIFFERENT scoped roles
# never share one. Same-shape plus roles-must-differ therefore leaves exactly
# the framework-wide pairs, which is what the enums now advertise. A change to
# or from a lead role is remove + add.
#
# This surface is MCP-first: the web UI models every role change as remove +
# add, so the underlying `change_collaborator_role` command has no web caller.
class Operations::Frameworks::ChangeCollaboratorRole < Operations::Base
  include Operations::Frameworks::CollaboratorScopeRules

  description "Change a collaborator's framework-wide role on a framework (e.g. viewer → editor). Only the framework-wide roles (owner/editor/collaborator/viewer) can be changed in place: to move a person to or from a scoped lead role, call frameworks_remove_collaborator for the old role then frameworks_add_collaborator for the new one."
  category :write
  approval :in_app

  parameter :framework_id, String, required: true
  parameter :person_id,    String, required: true
  parameter :old_role,     String, required: true, allowed: FRAMEWORK_WIDE_ROLES
  parameter :new_role,     String, required: true, allowed: FRAMEWORK_WIDE_ROLES
  parameter :scope_type,   String, allowed: SCOPE_BY_ROLE.values
  parameter :scope_id,     String

  # Every role this operation accepts is framework-wide, so a scope pair is
  # never meaningful — the forbid covers the whole enum. The two parameters
  # stay DECLARED rather than being dropped: an undeclared key is silently
  # discarded by validate_params, which is the silent-drop anti-pattern this
  # work exists to remove. Supplied, they are loudly rejected.
  forbids_when :scope_type, if: :new_role, in: FRAMEWORK_WIDE_ROLES,
                            message: FRAMEWORK_WIDE_MESSAGE
  forbids_when :scope_id, if: :new_role, in: FRAMEWORK_WIDE_ROLES,
                          message: FRAMEWORK_WIDE_MESSAGE

  # Tenant admins and framework owners may curate collaborators.
  # @raise [Pundit::NotAuthorizedError]
  def policy_check
    authorize framework, :manage_collaborators?
  end

  # @return [Hash] { framework_id:, person_id:, old_role:, new_role:, scope_type:, scope_id:, changed: }
  def perform
    validate_roles_differ!
    ensure_currently_held!
    ensure_target_not_held!

    Frameworks::CommandHandler.new.change_collaborator_role(
      framework.framework_id, params[:person_id],
      params[:old_role], params[:new_role],
      scope_type: scope_type, scope_id: scope_id,
      changed_by: actor_id
    )

    {
      framework_id: framework.framework_id,
      person_id: params[:person_id],
      old_role: params[:old_role],
      new_role: params[:new_role],
      scope_type: scope_type,
      scope_id: scope_id,
      changed: true
    }
  end

  private

  def validate_roles_differ!
    return if params[:old_role] != params[:new_role]

    raise Operations::Base::ParameterError, "new_role must differ from old_role"
  end

  def ensure_currently_held!
    return if collaborator_assignment(params[:old_role]).exists?

    raise Operations::Base::ParameterError,
          "person does not hold #{params[:old_role]} on this framework with this scope"
  end

  # Without this pre-check the projection would fold the changed row onto an
  # existing identical assignment, leaving a duplicate read-model row.
  def ensure_target_not_held!
    return unless collaborator_assignment(params[:new_role]).exists?

    raise Operations::Base::ParameterError,
          "person already holds #{params[:new_role]} on this framework with this scope"
  end

  # No `explorer_graph`: the concern needs one only for
  # `ensure_scope_entity_exists!`, and this operation's scope is always nil, so
  # there is never an entity to resolve. AddCollaborator still provides one.
  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end
end
