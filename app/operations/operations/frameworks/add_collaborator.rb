# frozen_string_literal: true

# Grants a person a collaborator role on a framework — framework-wide
# (owner / editor / collaborator / viewer) or scoped to one role family,
# role, capability category, or capability (the four lead roles).
#
# A person can hold multiple roles on the same framework; permissions are
# the union of all held roles (additive, never subtractive — see
# docs/guidelines/authorization.md). Granting a role changes what someone
# else can do, so this routes to :in_app approval — an MCP agent hands off
# to the web UI for confirmation; the web collaborator surfaces (which are
# the in-app surface) run it directly.
class Operations::Frameworks::AddCollaborator < Operations::Base
  include Operations::Frameworks::CollaboratorScopeRules

  description "Grant a person a collaborator role on a framework — framework-wide (owner/editor/collaborator/viewer) or scoped via scope_type + scope_id (the four lead roles)."
  category :write
  approval :in_app

  parameter :framework_id, String, required: true
  parameter :person_id,    String, required: true
  parameter :role,         String, required: true, allowed: FrameworkState::Collaborator::ROLES
  parameter :scope_type,   String, allowed: SCOPE_BY_ROLE.values
  parameter :scope_id,     String

  # Tenant admins and framework owners may curate collaborators.
  # @raise [Pundit::NotAuthorizedError]
  def policy_check
    authorize framework, :manage_collaborators?
  end

  # @return [Hash] { framework_id:, person_id:, role:, scope_type:, scope_id:, added: }
  def perform
    validate_scope_pair!(params[:role])
    ensure_scope_entity_exists!
    ensure_not_already_held!

    Frameworks::CommandHandler.new.add_collaborator(
      framework.framework_id, person.id, params[:role],
      scope_type: scope_type, scope_id: scope_id,
      added_by: actor_id
    )

    {
      framework_id: framework.framework_id,
      person_id: person.id,
      role: params[:role],
      scope_type: scope_type,
      scope_id: scope_id,
      added: true
    }
  end

  private

  # Pre-check the duplicate so a client mistake classifies as invalid
  # params, not the aggregate's RuntimeError (→ internal error over MCP).
  def ensure_not_already_held!
    return unless collaborator_assignment(params[:role]).exists?

    raise Operations::Base::ParameterError,
          "person already holds #{params[:role]} on this framework with this scope"
  end

  # acts_as_tenant scopes the lookup, so a cross-tenant person_id reads as
  # not-found rather than leaking existence.
  def person
    @person ||= Person.find(params[:person_id])
  end

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end

  def explorer_graph
    @explorer_graph ||= Frameworks::ExplorerGraph.load(framework.framework_id) ||
                        Frameworks::ExplorerGraph.rebuild(framework.framework_id)
  end
end
