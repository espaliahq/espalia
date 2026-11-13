# frozen_string_literal: true

# What the viewer may change in one unit's drawer (#124), resolved from
# {OrgGraphPolicy} so the view only reads flags. The commands check again.
#
# A unit an HRIS supplies keeps its name and parent there. Its owners, and
# the members someone added by hand, stay editable here (#115).
class OrgGraphPolicy::UnitRights
  # @param policy [OrgGraphPolicy]
  # @param unit [OrgUnit]
  # @param overview [OrgGraph::UnitsOverview] the live units, for destinations
  def initialize(policy, unit, overview)
    @policy = policy
    @unit = unit
    @overview = overview
  end

  # @return [Boolean]
  def rename? = @unit.held_by_espalia? && @policy.edit_unit?(@unit)

  # @return [Boolean]
  def move? = rename? && (parent_choices.any? || root_choice?)

  # @return [Boolean]
  def owners? = @policy.edit_unit?(@unit)

  # @return [Boolean]
  def add_members? = @policy.edit_unit?(@unit)

  # Where the unit may move: any live unit outside its own subtree that the
  # viewer may put a unit under.
  #
  # @return [Array<OrgUnit>] in tree order
  def parent_choices
    @parent_choices ||= begin
      subtree = [ @unit, *@overview.descendants_of(@unit) ]
      @overview.in_tree_order.reject { |unit| subtree.include?(unit) }.select { |unit| @policy.create_unit?(unit) }
    end
  end

  # @return [Boolean] whether the unit may sit at the root
  def root_choice? = @policy.create_unit?(nil)

  # @param membership [OrgMembership]
  # @return [Boolean] whether the viewer may move or remove it
  def member?(membership)
    membership.provider == OrgGraph::StructureAggregate::ESPALIA &&
      @policy.edit_membership?(membership.person, @unit)
  end

  # @param membership [OrgMembership]
  # @return [Array<OrgUnit>] the units the viewer may move it to, in tree order
  def destinations(membership)
    return [] unless member?(membership)

    @overview.in_tree_order.select do |unit|
      unit != @unit && @policy.move_membership?(membership.person, @unit, unit)
    end
  end
end
