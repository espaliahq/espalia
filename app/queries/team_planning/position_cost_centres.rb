# frozen_string_literal: true

# Each position's cost centre on a map, and how it was reached
# ([#325](https://github.com/espaliahq/espalia/issues/325)). The first of
# these that gives one wins:
#
# 1. the position's own label;
# 2. for a filled position, an occupant's cost centre in the Org Graph, the
#    largest allocation first;
# 3. the cost centre rules read at the position's unit, the first match
#    winning, its index kept so a later check can flag two that both match.
#
# Otherwise it has none. The rule index is a place in the list the position's
# unit reads, wherever up the units that list was set. A placeholder hire
# has no cost centre of their own, so they never give one in step 2.
#
# @example
#   TeamPlanning::PositionCostCentres.new(map, tenant_id:).of(position)
#   # => Resolved(cost_centre: "Platform", source: "rule", rule_index: 0)
class TeamPlanning::PositionCostCentres
  SOURCES = %w[position person rule none].freeze

  # @!attribute cost_centre [String, nil]
  # @!attribute source [String] a {SOURCES} entry
  # @!attribute rule_index [Integer, nil] the winning rule's place in the list, for "rule"
  Resolved = Data.define(:cost_centre, :source, :rule_index) do
    def initialize(rule_index: nil, **) = super
  end

  NONE = Resolved.new(cost_centre: nil, source: "none")

  # @param map [TeamPlanning::Baseline::Map]
  # @param tenant_id [String]
  def initialize(map, tenant_id:)
    @map = map
    @tenant_id = tenant_id
    @resolved = {}
    @chains = {}
  end

  # @param position [TeamPlanning::Baseline::Position]
  # @return [Resolved]
  def of(position)
    @resolved[position.id] ||= own(position) || occupied(occupants.fetch(position.id, [])) || ruled(position) || NONE
  end

  private

  def occupants = @occupants ||= @map.occupants

  def live = @live ||= @map.units.to_set(&:id)

  def own(position) = position.cost_centre && Resolved.new(cost_centre: position.cost_centre, source: "position")

  def occupied(held)
    person, = held.sort_by { |person, place| [ -place.allocation.to_f, person.id ] }.find { |person, _| person.cost_centre.present? }
    person && Resolved.new(cost_centre: person.cost_centre, source: "person")
  end

  def ruled(position)
    unit_id = position.unit_id if live.include?(position.unit_id)
    entry, index = TeamPlanning::RuleKinds::CostCentre.match(rules_at(unit_id), unit_ids: chain(unit_id), role_id: position.role_id,
                                                                                role_family_id: families[position.role_id])
    entry && Resolved.new(cost_centre: entry["cost_centre"], source: "rule", rule_index: index)
  end

  def rules_at(unit_id) = (@rules ||= {})[unit_id] ||= @map.rule("cost_centre", unit_id:)

  def chain(unit_id) = unit_id ? @chains[unit_id] ||= @map.units_up_from(unit_id) : []

  def families
    @families ||= FrameworkState::Role.where(tenant_id: @tenant_id, role_id: @map.positions.map(&:role_id).uniq).pluck(:role_id, :role_family_id).to_h
  end
end
