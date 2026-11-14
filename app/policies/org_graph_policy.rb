# frozen_string_literal: true

# Who may change the Org Graph: a tenant's units, its taxonomy and providers,
# and the memberships and facts of its people.
#
# Authorize against the `:org_graph` symbol. A unit predicate takes the
# {OrgUnit} it acts on, a membership predicate the {Person} and the unit.
#
# - A tenant admin or an Org Graph editor may change anything but the
#   taxonomy, whose shape only a tenant admin may change.
# - A unit's owners may change it and every unit beneath it. Owning any unit
#   up the chain counts, so a unit with no owner of its own inherits its
#   parent's.
# - A person's manager chain may change that person's memberships, in units
#   they don't own.
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

  # Add a level to the taxonomy, rename one or change their order. Admins
  # only: every unit sits at a level, so the taxonomy's shape is a bigger call
  # than any one unit.
  #
  # @return [Boolean]
  def edit_taxonomy? = tenant_admin?

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
    edit_structure? || (tenant_member? && unit.present? && unit.owned_by?(person))
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
    edit_structure? || (member.present? && (manages?(member) || edit_unit?(unit)))
  end

  # @param member [Person]
  # @param from_unit [OrgUnit]
  # @param to_unit [OrgUnit]
  # @return [Boolean]
  def move_membership?(member, from_unit, to_unit)
    edit_structure? || (member.present? && (manages?(member) || (edit_unit?(from_unit) && edit_unit?(to_unit))))
  end

  private

  def manages?(member)
    tenant_member? && person&.status == "active" && member.present? && member.managed_by?(person)
  end
end
