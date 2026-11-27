# frozen_string_literal: true

# Who may change the Org Graph: a tenant's units, its taxonomy and providers,
# and the memberships and facts of its people.
#
# Authorize against the `:org_graph` symbol. A unit predicate takes the
# {OrgUnit} it acts on, a membership predicate the {Person} and the unit.
#
# - A tenant admin or an Org Graph editor may change anything.
# - A unit's owners, and everyone above them in the current reporting line,
#   may change that unit and every unit beneath it, its structure included
#   ({Reach}). Owning any unit up the chain counts.
# - A person's manager chain may change that person's memberships, in units
#   they have no rights over.
#
# The whole tenant can see the Org Graph.
#
# @example
#   authorize :org_graph, :show?
#   OrgGraphPolicy.new(context, :org_graph).edit_unit?(unit)
class OrgGraphPolicy < ApplicationPolicy
  # @return [Boolean]
  def show? = tenant_member?

  # The Units view, its drawers and its MCP reads, for anyone who holds a
  # right in the Org Graph: an admin, an editor, an active person whose
  # {Reach} covers a unit, or one with an active direct report to place.
  # Opening it to {#show?} is a later decision (#80).
  #
  # @return [Boolean]
  def show_units?
    edit_structure? || (active_member? && (reach.owned_unit_ids.any? || person.direct_reports.active.exists?))
  end

  # The settings screen: sources, levels, freshness, forgetting and who may
  # edit. Each panel's write keeps its own predicate.
  #
  # @return [Boolean]
  def edit_settings? = tenant_admin?

  # Add a type to the organisation's structure, rename one or say where it
  # may sit.
  #
  # @return [Boolean]
  def edit_taxonomy? = edit_structure_of?(nil)

  # Declare, withdraw or edit the structure a unit gives the units beneath it
  # (#494), or, given nil, the organisation's own.
  #
  # @param unit [OrgUnit, nil] the declaring unit, nil for the organisation's
  # @return [Boolean]
  def edit_structure_of?(unit)
    edit_structure? || (unit.present? && active_member? && reach.covers?(unit))
  end

  # The providers, units at the root, and people's facts.
  #
  # @return [Boolean]
  def edit_structure?
    tenant_admin? || context.org_graph_editor?
  end

  # Rename, retire, or name and remove owners.
  #
  # @param unit [OrgUnit, nil] nil for a unit the Org Graph doesn't hold,
  #   which only an admin or an editor may name
  # @return [Boolean]
  def edit_unit?(unit)
    edit_structure? || (active_member? && reach.covers?(unit))
  end

  # @param parent [OrgUnit, nil] nil for a unit at the root
  # @return [Boolean]
  def create_unit?(parent)
    parent ? edit_unit?(parent) : edit_structure?
  end

  # A move needs rights at both ends: on the unit, and where it lands.
  #
  # @param unit [OrgUnit]
  # @param new_parent [OrgUnit, nil] nil for a move to the root
  # @return [Boolean]
  def move_unit?(unit, new_parent)
    edit_unit?(unit) && create_unit?(new_parent)
  end

  # A unit's type is part of the structure in force where it sits, so
  # retyping it needs the right to change that structure.
  #
  # @param structure_unit [OrgUnit, nil] the unit whose structure is in force,
  #   nil for the organisation's
  # @return [Boolean]
  def change_unit_kind?(structure_unit) = edit_structure_of?(structure_unit)

  # @param units [Enumerable<OrgUnit>] every predecessor and successor
  # @return [Boolean]
  def record_succession?(units)
    units.all? { |unit| edit_unit?(unit) }
  end

  # Place a person in a unit, or end their membership of it.
  #
  # @param member [Person]
  # @param unit [OrgUnit]
  # @return [Boolean]
  def edit_membership?(member, unit)
    edit_structure? || (member.present? && place?(member, unit))
  end

  # @param member [Person]
  # @param unit [OrgUnit]
  # @return [Boolean] whether the caller's rights over the unit, or over the
  #   member as their manager, let them place the member there
  def place?(member, unit)
    edit_unit?(unit) || manages?(member)
  end

  # @param member [Person]
  # @param from_unit [OrgUnit]
  # @param to_unit [OrgUnit]
  # @return [Boolean]
  def move_membership?(member, from_unit, to_unit)
    edit_structure? || (member.present? && (manages?(member) || (edit_unit?(from_unit) && edit_unit?(to_unit))))
  end

  private

  def active_member? = tenant_member? && person&.status == "active"

  def reach
    @reach ||= OrgGraphPolicy::Reach.new(person)
  end

  def manages?(member)
    active_member? && member.present? && member.managed_by?(person)
  end
end
