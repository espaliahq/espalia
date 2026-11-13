# frozen_string_literal: true

# What the viewer may change in one person's drawer (#132), resolved from
# {OrgGraphPolicy} so the view only reads flags. The commands check again.
#
# A membership an HRIS supplies stays with the HRIS; one added by hand can be
# moved and ended here. A forgotten person has no memberships left to change.
class OrgGraphPolicy::PersonRights
  # @param policy [OrgGraphPolicy]
  # @param person [Person]
  # @param overview [OrgGraph::UnitsOverview] the live units, for choices
  # @param memberships [Array<OrgMembership>] the person's memberships of live units
  def initialize(policy, person, overview, memberships)
    @policy = policy
    @person = person
    @overview = overview
    @memberships = memberships
  end

  # @param membership [OrgMembership]
  # @return [Boolean] whether the viewer may move or end it
  def membership?(membership)
    !@person.forgotten? && membership.provider == OrgGraph::StructureAggregate::ESPALIA &&
      @policy.edit_membership?(@person, membership.unit)
  end

  # @param membership [OrgMembership]
  # @return [Array<OrgUnit>] the units it may move to, in tree order
  def destinations(membership)
    return [] unless membership?(membership)

    open_units.select { |unit| @policy.move_membership?(@person, membership.unit, unit) }
  end

  # @return [Array<OrgUnit>] the units the viewer may add the person to, in tree order
  def join_choices
    return [] if @person.forgotten?

    @join_choices ||= open_units.select { |unit| @policy.edit_membership?(@person, unit) }
  end

  # @return [Boolean]
  def join? = join_choices.any?

  private

  def open_units
    held = @memberships.map(&:unit_id)
    @overview.in_tree_order.reject { |unit| held.include?(unit.id) }
  end
end
