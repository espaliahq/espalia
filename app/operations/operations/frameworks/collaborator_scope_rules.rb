# frozen_string_literal: true

# Shared validation for the collaborator-management Operations
# ({Operations::Frameworks::AddCollaborator} / ChangeCollaboratorRole /
# RemoveCollaborator).
#
# Collaborator roles come in two shapes: framework-wide (owner, editor,
# collaborator, viewer) and scoped leads, each tied to one entity type
# (role_family_lead → role_family, etc). The aggregate stores whatever it is
# given, so these Operations enforce the coherence the web form guarantees
# structurally (its scope picker is driven by the selected role): a scoped
# role must carry a matching scope pair, a framework-wide role must carry
# none, and the scoped entity must exist in this framework.
#
# Includers must provide `params`, `framework`, and `explorer_graph`.
module Operations::Frameworks::CollaboratorScopeRules
  # Scoped lead roles and the entity type each is scoped to. Roles absent
  # from this map are framework-wide and take no scope.
  SCOPE_BY_ROLE = {
    "role_family_lead"         => "role_family",
    "role_lead"                => "role",
    "capability_category_lead" => "capability_category",
    "capability_lead"          => "capability"
  }.freeze

  private

  def scope_type = params[:scope_type].presence
  def scope_id   = params[:scope_id].presence

  def actor_id
    context.person&.id&.to_s
  end

  # Enforces the role/scope pairing for the role being granted.
  def validate_scope_pair!(role)
    expected = SCOPE_BY_ROLE[role]

    if expected.nil?
      return if scope_type.nil? && scope_id.nil?

      raise Operations::Base::ParameterError,
            "#{role} is framework-wide — omit scope_type and scope_id"
    end

    return if scope_type == expected && scope_id.present?

    raise Operations::Base::ParameterError,
          "#{role} is scoped — provide scope_type \"#{expected}\" and a scope_id"
  end

  # The scoped entity must exist in this framework. Resolved from the
  # explorer graph so entities added in the current draft count too, and so
  # the id is scoped to the authorized framework.
  def ensure_scope_entity_exists!
    return if scope_id.nil?
    return if scope_entity_ids.include?(scope_id)

    raise ActiveRecord::RecordNotFound,
          "#{scope_type} #{scope_id} not found in this framework"
  end

  def scope_entity_ids
    families = explorer_graph.role_families
    categories = explorer_graph.capability_categories

    case scope_type
    when "role_family"        then families.map(&:role_family_id)
    when "role"               then families.flat_map(&:roles).map(&:role_id)
    when "capability_category" then categories.map(&:category_id)
    when "capability"         then categories.flat_map(&:capabilities).map(&:capability_id)
    else []
    end
  end

  # The exact (person, role, scope) assignment, if it exists. The read model
  # is projected synchronously from the same events the aggregate folds, so
  # it mirrors the aggregate's @collaborators keys.
  def collaborator_assignment(role)
    FrameworkState::Collaborator
      .for_framework(framework.framework_id)
      .where(person_id: params[:person_id], role: role,
             scope_type: scope_type, scope_id: scope_id)
  end
end
