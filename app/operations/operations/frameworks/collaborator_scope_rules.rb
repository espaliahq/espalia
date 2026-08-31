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
# The first two are declared via `declare_collaborator_scope_rules`, so they
# are advertised in the tool schema as well as enforced; existence is a lookup
# the schema can't express and stays in `ensure_scope_entity_exists!`.
#
# Includers must provide `params`, `framework`, and `explorer_graph`.
module Operations::Frameworks::CollaboratorScopeRules
  extend ActiveSupport::Concern

  # Scoped lead roles and the entity type each is scoped to. Roles absent
  # from this map are framework-wide and take no scope.
  SCOPE_BY_ROLE = {
    "role_family_lead"         => "role_family",
    "role_lead"                => "role",
    "capability_category_lead" => "capability_category",
    "capability_lead"          => "capability"
  }.freeze

  # Derived from the same list of roles, so a new role can't fall outside both
  # halves of the rule.
  FRAMEWORK_WIDE_ROLES = (FrameworkState::Collaborator::ROLES - SCOPE_BY_ROLE.keys).freeze

  # Established copy — these reach the collaborator screens as a flash, so they
  # keep the domain wording rather than the generic parameter-speak.
  SCOPED_MESSAGE = lambda do |role|
    "#{role} is scoped — provide scope_type \"#{SCOPE_BY_ROLE[role]}\" and a scope_id"
  end
  FRAMEWORK_WIDE_MESSAGE = ->(role) { "#{role} is framework-wide — omit scope_type and scope_id" }

  class_methods do
    # Declares the whole role/scope pairing against `trigger` — the parameter
    # naming the role being granted (`:role` on add, `:new_role` on change).
    #
    # Three rules, each enforced at the parameter boundary AND advertised in the
    # tool schema (mcp-server.md Lesson 15): a scoped lead role needs a scope_id
    # and a scope_type PINNED to that role's entity type; a framework-wide role
    # accepts neither. Call it after the parameters it names are declared.
    #
    # @param trigger [Symbol] the role parameter whose value decides
    def declare_collaborator_scope_rules(trigger)
      # One rule per role, because each pins a DIFFERENT scope_type. No message
      # override: the pin's own default names the value ("scope_type must be
      # \"role\" when role is \"role_lead\""), whereas SCOPED_MESSAGE would also
      # claim a scope_id was missing when the caller supplied a valid one.
      SCOPE_BY_ROLE.each do |role, expected_scope_type|
        requires_when :scope_type, if: trigger, equals: role, must_be: expected_scope_type
      end

      # scope_id carries no per-role value, so the four roles share one rule.
      requires_when :scope_id, if: trigger, in: SCOPE_BY_ROLE.keys, message: SCOPED_MESSAGE

      forbids_when :scope_type, if: trigger, in: FRAMEWORK_WIDE_ROLES, message: FRAMEWORK_WIDE_MESSAGE
      forbids_when :scope_id, if: trigger, in: FRAMEWORK_WIDE_ROLES, message: FRAMEWORK_WIDE_MESSAGE
    end
  end

  private

  def scope_type = params[:scope_type].presence
  def scope_id   = params[:scope_id].presence

  def actor_id
    context.person&.id&.to_s
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
