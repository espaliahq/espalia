# frozen_string_literal: true

# Each position's cost centre on a map, and how it was reached
# ([#325](https://github.com/espaliahq/espalia/issues/325)). The first of
# these that gives one wins:
#
# 1. the position's own label;
# 2. for a filled position, the cost centre in the Org Graph of an occupant
#    the plan leaves untouched ({#changed?}), the largest allocation first;
# 3. the cost centre rules read at the position's unit, the last entry that
#    matches its unit, role, family or level having the last word
#    ([#387](https://github.com/espaliahq/espalia/issues/387)). An open
#    position has no location, so an entry that names one never decides it.
#
# Otherwise it has none. The rule index is a place in the list the position's
# unit reads, wherever up the units that list was set, and the matcher is
# that entry's, so the working can name it. A placeholder hire has no cost
# centre of their own, so they never give one in step 2.
#
# @example
#   TeamPlanning::PositionCostCentres.new(map, tenant_id:, base:, titles:).of(position)
#   # => Resolved(cost_centre: "Platform", source: "rule", rule_index: 0, rule_matcher: { "unit_id" => "…" })
class TeamPlanning::PositionCostCentres
  SOURCES = %w[position person rule none].freeze

  # @!attribute cost_centre [String, nil]
  # @!attribute source [String] a {SOURCES} entry
  # @!attribute rule_index [Integer, nil] the deciding entry's place in the list, for "rule"
  # @!attribute rule_matcher [Hash, nil] the deciding entry without its label, for "rule"
  Resolved = Data.define(:cost_centre, :source, :rule_index, :rule_matcher) do
    def initialize(rule_index: nil, rule_matcher: nil, **) = super
  end

  NONE = Resolved.new(cost_centre: nil, source: "none")

  # @param map [TeamPlanning::Baseline::Map]
  # @param tenant_id [String]
  # @param base [TeamPlanning::Baseline::Map] Today, which {#changed?} compares the map with
  # @param titles [Integrations::HrisTitleResolution] each person's own role and level
  def initialize(map, tenant_id:, base:, titles:)
    @map = map
    @tenant_id = tenant_id
    @base = base
    @titles = titles
    @resolved = {}
    @chains = {}
  end

  # @param position [TeamPlanning::Baseline::Position]
  # @return [Resolved]
  def of(position)
    @resolved[position.id] ||= own(position) || occupied(occupants.fetch(position.id, [])) || ruled(position) || NONE
  end

  # A person's cost centre in one of their places
  # ([#387](https://github.com/espaliahq/espalia/issues/387)). Someone with a
  # real cost centre keeps it unless the plan changes their unit, role, level
  # or location. Otherwise the first of these that gives one wins: their
  # position's own label; the entries read at their planned place; their real
  # cost centre. A placeholder hire reads as its position's open seat, {#of},
  # so its caller sends one here only when it holds no position.
  #
  # @param cost_centre [String, nil] their real cost centre
  # @param changed [Boolean] whether the plan changes their unit, role, level or location
  # @param position [TeamPlanning::Baseline::Position, nil] the position the place is in
  # @param unit_id [String, nil] the place's live unit
  # @param role_id [String, nil] the role they hold there
  # @param level_id [String, nil] the level they are priced at there
  # @param location [String, nil] their country
  # @return [Resolved]
  def person(cost_centre:, changed:, position:, unit_id:, role_id:, level_id:, location:)
    real = Resolved.new(cost_centre:, source: "person") if cost_centre.present?
    return real if real && !changed

    (position && own(position)) ||
      by_rules(unit_id:, role_id:, level_id:, location:) || real || NONE
  end

  # Whether the plan changes what a cost centre entry can see of them: their
  # units, the role they hold in each, the level they are priced at there or
  # their location. A changed FTE alone does not count, and neither does a
  # placeholder hire, which Today never holds.
  #
  # @param member [TeamPlanning::Baseline::Person]
  # @return [Boolean]
  def changed?(member)
    @changed ||= {}
    return @changed[member.id] if @changed.key?(member.id)

    today = today_people[member.id]
    # no path builds a scenario person missing from Today yet
    @changed[member.id] = !member.placeholder? && !today.nil? &&
                          (situation(member, @map) != situation(today, @base) || member.country != today.country)
  end

  # @param member [TeamPlanning::Baseline::Person]
  # @param position [TeamPlanning::Baseline::Position, nil]
  # @return [String, nil] the role they hold in the position, else their own
  def role_at(member, position) = position&.role_id || member.own_target(@titles).role&.role_id

  private

  def occupants = @occupants ||= @map.occupants

  def today_people = @today_people ||= (@base.people + @base.outside).index_by(&:id)

  def situation(member, map)
    positions, live = (@layouts ||= {})[map.object_id] ||= [ map.positions.index_by(&:id), map.units.to_set(&:id) ]
    own_level_id = member.own_target(@titles).level&.level_id
    places = member.memberships.to_set do
      position = positions[it.position_id]
      [ (it.unit_id if live.include?(it.unit_id)), role_at(member, position), own_level_id || position&.level_id ]
    end
    [ places, own_level_id ]
  end

  def live = @live ||= @map.units.to_set(&:id)

  def own(position) = position.cost_centre && Resolved.new(cost_centre: position.cost_centre, source: "position")

  def occupied(held)
    person, = held.sort_by { |person, place| [ -place.allocation.to_f, person.id ] }.find { |person, _| person.cost_centre.present? && !changed?(person) }
    person && Resolved.new(cost_centre: person.cost_centre, source: "person")
  end

  def ruled(position)
    by_rules(unit_id: (position.unit_id if live.include?(position.unit_id)), role_id: position.role_id, level_id: position.level_id, location: nil)
  end

  def by_rules(unit_id:, role_id:, level_id:, location:)
    return if TeamPlanning::RuleKinds::CostCentre.entries(rules_at(unit_id)).empty?

    entry, index = TeamPlanning::RuleKinds::CostCentre.match(rules_at(unit_id), unit_ids: chain(unit_id), role_id:, role_family_id: family(role_id),
                                                                                level_ordinal: ordinal(level_id), location:)
    entry && Resolved.new(cost_centre: entry["cost_centre"], source: "rule", rule_index: index, rule_matcher: entry.except("cost_centre"))
  end

  def rules_at(unit_id) = (@rules ||= {})[unit_id] ||= @map.rule("cost_centre", unit_id:)

  def chain(unit_id) = unit_id ? @chains[unit_id] ||= @map.units_up_from(unit_id) : []

  def ordinal(level_id)
    @ordinals ||= FrameworkState::Level.where(tenant_id: @tenant_id).pluck(:level_id, :ordinal).to_h
    @ordinals[level_id]
  end

  def family(role_id)
    @families ||= FrameworkState::Role.where(tenant_id: @tenant_id).pluck(:role_id, :role_family_id).to_h
    @families[role_id]
  end
end
