# frozen_string_literal: true

# Changes a collaborator's role on a framework within the same scope —
# e.g. promote a framework-wide viewer to editor.
#
# The scope pair stays fixed across the change (the aggregate keys the old
# and new assignment on the same scope), so old_role and new_role must
# share a scope shape: both framework-wide, or both scoped to the same
# entity type. Permission-changing → :in_app approval.
#
# This surface is MCP-first: the web UI models a role change as remove +
# add, so the underlying `change_collaborator_role` command had no
# user-facing caller until this Operation.
class Operations::Frameworks::ChangeCollaboratorRole < Operations::Base
  include Operations::Frameworks::CollaboratorScopeRules

  description "Change a collaborator's role on a framework within the same scope (e.g. viewer → editor). Moving between differently-scoped roles requires remove + add."
  category :write
  approval :in_app

  parameter :framework_id, String, required: true
  parameter :person_id,    String, required: true
  parameter :old_role,     String, required: true, allowed: FrameworkState::Collaborator::ROLES
  parameter :new_role,     String, required: true, allowed: FrameworkState::Collaborator::ROLES
  parameter :scope_type,   String, allowed: SCOPE_BY_ROLE.values
  parameter :scope_id,     String

  def policy_check
    authorize framework, :manage_collaborators?
  end

  # @return [Hash] { framework_id:, person_id:, old_role:, new_role:, scope_type:, scope_id:, changed: }
  def perform
    validate_roles_differ!
    validate_same_scope_shape!
    validate_scope_pair!(params[:new_role])
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

  def validate_same_scope_shape!
    return if SCOPE_BY_ROLE[params[:old_role]] == SCOPE_BY_ROLE[params[:new_role]]

    raise Operations::Base::ParameterError,
          "#{params[:old_role]} and #{params[:new_role]} are scoped differently — remove the old role and add the new one instead"
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

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end

  def explorer_graph
    @explorer_graph ||= Frameworks::ExplorerGraph.load(framework.framework_id) ||
                        Frameworks::ExplorerGraph.rebuild(framework.framework_id)
  end
end
