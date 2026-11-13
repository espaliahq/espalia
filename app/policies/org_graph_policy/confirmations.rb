# frozen_string_literal: true

# Which stale facts the viewer sees, and which they may say are still true
# (#142), resolved from {OrgGraphPolicy} so the views only read answers. The
# command checks again.
#
# A membership is confirmed by whoever may change it; a person's own fact by
# an admin or Org Graph editor. Only a fact Espalia holds can be stale, since
# an HRIS confirms its own every sync.
class OrgGraphPolicy::Confirmations
  ESPALIA = OrgGraph::StructureAggregate::ESPALIA

  # The confirmations for the members of the cards the Units view shows.
  #
  # @param policy [OrgGraphPolicy]
  # @param overview [OrgGraph::UnitsOverview]
  # @return [OrgGraphPolicy::Confirmations]
  def self.for_cards(policy, overview)
    members = overview.cards.flat_map { |unit| overview.members_of(unit) }
    new(policy, overview, OrgGraph::StaleFacts.new(person_ids: members.map(&:person_id)))
  end

  # @param policy [OrgGraphPolicy]
  # @param overview [OrgGraph::UnitsOverview] the live units
  # @param stale [OrgGraph::StaleFacts] for the people on screen
  def initialize(policy, overview, stale)
    @policy = policy
    @overview = overview
    @stale = stale
  end

  # @param membership [OrgMembership]
  # @return [OrgFactAge, nil] when nobody has changed or confirmed it within the threshold
  def membership(membership) = @stale.membership(membership.person_id, membership.unit_id)

  # @param membership [OrgMembership]
  # @return [Boolean] whether the viewer may say it is still true
  def membership?(membership)
    unit = units[membership.unit_id] or return false

    membership.provider == ESPALIA && !membership.person.forgotten? &&
      @policy.edit_membership?(membership.person, unit)
  end

  # @param person [Person]
  # @param employment [String] the person drawer's employment key, such as "site"
  # @return [Array<OrgFactAge>] its stale facts, oldest first
  def employment(person, employment) = @stale.employment(person.id, employment)

  # @param person [Person]
  # @return [Boolean] whether the viewer may say the person's own facts are still true
  def facts?(person) = !person.forgotten? && edit_structure?

  private

  def units = @units ||= @overview.in_tree_order.index_by(&:id)

  def edit_structure? = @edit_structure.nil? ? (@edit_structure = @policy.edit_structure?) : @edit_structure
end
