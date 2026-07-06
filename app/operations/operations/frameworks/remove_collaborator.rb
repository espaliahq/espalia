# frozen_string_literal: true

# Removes a collaborator role from a person on a framework. Because roles
# are additive, removing one role never touches the person's other roles on
# the same framework.
#
# No scope-coherence validation on removal — the assignment is addressed by
# its exact (person, role, scope) key, so any historically-recorded pairing
# can be removed. Permission-changing → :in_app approval.
class Operations::Frameworks::RemoveCollaborator < Operations::Base
  include Operations::Frameworks::CollaboratorScopeRules

  description "Remove a collaborator role from a person on a framework (their other roles on the framework are untouched)."
  category :write
  approval :in_app

  parameter :framework_id, String, required: true
  parameter :person_id,    String, required: true
  parameter :role,         String, required: true, allowed: FrameworkState::Collaborator::ROLES
  parameter :scope_type,   String, allowed: SCOPE_BY_ROLE.values
  parameter :scope_id,     String

  def policy_check
    authorize framework, :manage_collaborators?
  end

  # @return [Hash] { framework_id:, person_id:, role:, scope_type:, scope_id:, removed: }
  def perform
    ensure_currently_held!

    Frameworks::CommandHandler.new.remove_collaborator(
      framework.framework_id, params[:person_id], params[:role],
      scope_type: scope_type, scope_id: scope_id,
      removed_by: actor_id
    )

    {
      framework_id: framework.framework_id,
      person_id: params[:person_id],
      role: params[:role],
      scope_type: scope_type,
      scope_id: scope_id,
      removed: true
    }
  end

  private

  # Pre-check so a wrong (person, role, scope) key classifies as invalid
  # params, not the aggregate's RuntimeError (→ internal error over MCP).
  def ensure_currently_held!
    return if collaborator_assignment(params[:role]).exists?

    raise Operations::Base::ParameterError,
          "person does not hold #{params[:role]} on this framework with this scope"
  end

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end
end
