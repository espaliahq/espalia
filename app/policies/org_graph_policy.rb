# frozen_string_literal: true

# Who may change the Org Graph: a tenant's units, its structures and
# providers, and the memberships and facts of its people.
#
# Authorize against the `:org_graph` symbol. A unit predicate takes the
# {OrgUnit} it acts on, a membership predicate the {Person} and the unit.
#
# The rule: a tenant admin or an Org Graph editor may change anything. Anyone
# else may change a unit, and the structure it declares, when they or someone
# below them on `people.manager_id` owns it or a unit above it ({Reach}). The
# organisation's own structure, which no unit owns, stays with admins and
# editors, and a unit's type belongs to the structure it sits in. A person's
# manager chain may also place that person in any unit. Only people still
# working here hold rights.
#
# The whole tenant can see the Org Graph.
#
# @example
#   authorize :org_graph, :show?
#   OrgGraphPolicy.new(context, :org_graph).edit_unit?(unit)
class OrgGraphPolicy < ApplicationPolicy
  # @return [Boolean]
  def show? = tenant_member?

  # The Units view and its MCP read. Admins only while the Org Graph's
  # screens are unfinished; it opens to {#show?} once they are (#80).
  #
  # @return [Boolean]
  def show_units? = tenant_admin?

  # The settings screen: sources, levels, freshness, forgetting and who may
  # edit. Each panel's write keeps its own predicate.
  #
  # @return [Boolean]
  def edit_settings? = tenant_admin?

  # Change the organisation's own structure: its unit types and where they
  # may sit.
  #
  # @return [Boolean]
  def edit_taxonomy? = edit_structure_of?(nil)

  # Declare, withdraw or edit the structure a unit gives the units beneath it
  # ([#494](https://github.com/espaliahq/espalia/issues/494)), or, given nil,
  # the organisation's.
  #
  # @param unit [OrgUnit, nil] the declaring unit, nil for the organisation's structure
  # @return [Boolean]
  def edit_structure_of?(unit) = edit_structure? || reaches?(unit)

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
  def edit_unit?(unit) = edit_structure? || reaches?(unit)

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

  # A unit's type decides what may sit above and beneath it, so changing it
  # needs the right over the structure the unit sits in. An owner who may move
  # a unit may not retype it on that alone.
  #
  # @param unit [OrgUnit, nil]
  # @return [Boolean]
  def change_unit_kind?(unit)
    edit_structure? || (reaches?(unit) && edit_structure_of?(structure_unit_of(unit)))
  end

  # @param units [Enumerable<OrgUnit>] every predecessor and successor
  # @return [Boolean]
  def record_succession?(units)
    units.all? { |unit| edit_unit?(unit) }
  end

  # Place a person in a unit, move them or end their membership of it: the
  # person's manager chain, or whoever may change the unit.
  #
  # @param member [Person, nil] nil for a person the Org Graph doesn't hold
  # @param unit [OrgUnit, nil]
  # @return [Boolean]
  def place?(member, unit)
    edit_structure? || (member.present? && (manages?(member) || edit_unit?(unit)))
  end

  # @param member [Person]
  # @param unit [OrgUnit]
  # @return [Boolean]
  def edit_membership?(member, unit) = place?(member, unit)

  # @param member [Person]
  # @param from_unit [OrgUnit]
  # @param to_unit [OrgUnit]
  # @return [Boolean]
  def move_membership?(member, from_unit, to_unit)
    edit_structure? || (member.present? && (manages?(member) || (edit_unit?(from_unit) && edit_unit?(to_unit))))
  end

  # The units the caller stands over, built once per policy.
  #
  # @return [OrgGraphPolicy::Reach]
  def reach = @reach ||= OrgGraphPolicy::Reach.new(active_member? ? person : nil)

  private

  def active_member? = tenant_member? && person&.status == "active"

  def reaches?(unit) = unit.present? && active_member? && reach.covers?(unit)

  # The nearest unit strictly above that declares a structure, nil for the organisation's.
  def structure_unit_of(unit)
    @declaring_unit_ids ||= OrgTaxonomyLevel.where.not(structure_unit_id: nil).distinct.pluck(:structure_unit_id).to_set
    reach.lineage(unit).drop(1).find { @declaring_unit_ids.include?(it.id) }
  end

  def manages?(member)
    active_member? && member.present? && member.managed_by?(person)
  end
end
