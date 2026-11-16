# frozen_string_literal: true

# What a scenario's forecast assumptions add to it, as rows per unit and step
# ([#351](https://github.com/espaliahq/espalia/issues/351)). Computed when
# read and never stored, so a row has no id, person or position: nothing can
# pin, clear, undo, note or approve it, and the change list never holds one.
#
# A step is the scenario's period, the unit cost and the timeline use. Today
# has no period, so it forecasts nothing: it is all actual.
#
# A kind reads the filled seats from the map and prices them through the
# caller's {Pricing}, so cost prices them under the caller's pay view and
# capacity under each seat's model. A caller that measures only one of the two
# leaves the other empty, and the rows then carry none of it.
#
# @example
#   TeamPlanning::Forecast.new(aggregate:, scenario_id:, map:).rows # => [Row, ...]
class TeamPlanning::Forecast
  # One assumption's addition to one unit in one step.
  #
  # @!attribute kind [String] the rule that forecast it
  # @!attribute unit_id [String, nil] nil for no unit
  # @!attribute cost_centre [String, nil] nil for no cost centre
  # @!attribute starts_on [Date]
  # @!attribute ends_on [Date]
  # @!attribute headcount [Rational] people added, or taken away when negative
  # @!attribute cost [Hash{String => Rational}] currency => amount over the step
  # @!attribute capacity [Hash{String => Rational}] capacity model => amount
  Row = Data.define(:kind, :unit_id, :cost_centre, :starts_on, :ends_on, :headcount, :cost, :capacity)

  # One person's place in a unit, in a seat they fill.
  #
  # @!attribute person_id [String]
  # @!attribute unit_id [String, nil] nil when the place is in no live unit
  # @!attribute cost_centre [String, nil] the person's own
  # @!attribute fte [Rational] their FTE times the place's share of it
  Filled = Data.define(:person_id, :unit_id, :cost_centre, :fte)

  # What one filled FTE in a unit costs a year and delivers, on average.
  #
  # @!attribute cost [Hash{String => Rational}] currency => yearly amount
  # @!attribute capacity [Hash{String => Rational}] capacity model => amount
  Average = Data.define(:cost, :capacity)
  NO_AVERAGE = Average.new(cost: {}, capacity: {})

  # Each filled place priced as the caller measures it, keyed by person id and
  # unit id. A place missing from a hash adds nothing, as an unpriced seat adds
  # nothing to the actual figure.
  #
  # @!attribute cost [Hash{Array(String, String) => Hash{String => Rational}}] currency => yearly amount per FTE
  # @!attribute capacity [Hash{Array(String, String) => Hash{String => Rational}}] model => what the place delivers
  Pricing = Data.define(:cost, :capacity) do
    def initialize(cost: {}, capacity: {}) = super

    # @param other [Pricing]
    # @return [Pricing] this one's cost with the other's capacity
    def with_capacity_of(other) = with(capacity: other.capacity)
  end

  # What a kind reads to forecast one step.
  #
  # @!attribute kind [Class<TeamPlanning::ForecastKind>]
  # @!attribute map [TeamPlanning::Baseline::Map] the scenario's resolved map
  # @!attribute step [Range<Date>]
  # @!attribute covered [Set<String>] subjects a planned change in the scenario's chain sets
  # @!attribute filled [Array<Filled>] places in filled seats: not a planned leaver's or a placeholder's
  # @!attribute averages [Hash{String, nil => Average}] by unit
  Frame = Data.define(:kind, :map, :step, :covered, :filled, :averages) do
    def initialize(filled: [], averages: {}, **) = super

    # @param unit_id [String, nil]
    # @return [Average] what a filled FTE of the unit costs and delivers
    def average(unit_id) = averages.fetch(unit_id, NO_AVERAGE)

    # @param subject_id [String] a person, position or unit
    # @return [Boolean] whether a planned change already says what happens to it
    def covered?(subject_id) = covered.include?(subject_id)

    # @param unit_id [String, nil]
    # @return [Hash] the kind's rule as it resolves at that unit
    def rule_at(unit_id) = map.rule(kind.rule_name, unit_id:)

    # @return [Row] a row of this kind for this step
    def row(unit_id:, cost_centre: nil, headcount: 0r, cost: {}, capacity: {})
      Row.new(kind: kind.rule_name, unit_id:, cost_centre:, starts_on: step.begin, ends_on: step.end, headcount:, cost:, capacity:)
    end
  end

  # @param aggregate [TeamPlanning::PlanAggregate]
  # @param scenario_id [String] a scenario, or the plan's id for Today
  # @param map [TeamPlanning::Baseline::Map] the scenario's resolved map
  # @param pricing [Pricing] the scenario's filled places, priced as the caller sees them
  def initialize(aggregate:, scenario_id:, map:, pricing: Pricing.new)
    @aggregate = aggregate
    @scenario_id = scenario_id
    @map = map
    @pricing = pricing
  end

  # Today has no period, so no rows; nor has an id the plan doesn't hold, so a
  # caller resolves the scenario first.
  #
  # @return [Array<Row>] every forecast kind's rows, by kind, unit and step
  def rows
    step = @aggregate.period_of(@scenario_id) or return []

    covered = @aggregate.resolution_chain(@scenario_id).flat_map { @aggregate.changes_in(it) }.to_set { it.data[:subject_id] }
    filled = filled_places
    averages = averages(filled)
    TeamPlanning::RuleKinds.forecasts.flat_map do |kind|
      kind.forecast(Frame.new(kind:, map: @map, step:, covered:, filled:, averages:)).each do |row|
        raise ArgumentError, "#{kind} forecast something other than a row" unless row.is_a?(Row)
      end
    end
  end

  private

  # A filled seat is a person's: an open position fills none. A planned leaver
  # and a placeholder hire are left out, as the plan already says what happens
  # to them; a change to pay, level or place keeps the seat filled. A person's
  # places share their FTE as cost shares it, and a place outside a scoped
  # plan drops out as it does from cost.
  def filled_places
    live = @map.units.to_set(&:id)
    @map.people.reject { it.leaving? || it.placeholder? }.flat_map do |person|
      fte = Rational(person.fte_or_one.to_s)
      places = TeamPlanning::Baseline::Membership.shares(person.memberships)
      weight = places.sum(0r) { Rational(it[1].to_s) }
      cost_centre = person.cost_centre.presence
      next [ Filled.new(person_id: person.id, unit_id: nil, cost_centre:, fte:) ] unless weight.positive?

      away = @map.outside_places(person)
      places.reject { |placement, _| away.include?(placement) }.map do |placement, share, _|
        Filled.new(person_id: person.id, unit_id: live.include?(placement.unit_id) ? placement.unit_id : nil, cost_centre:,
                   fte: fte * Rational(share.to_s) / weight)
      end
    end
  end

  # Each unit's figures over all its filled FTE. An unpriced place adds to the
  # FTE and nothing to the figure, so attrition never takes away more than the
  # actual figure holds.
  def averages(filled)
    filled.group_by(&:unit_id).transform_values do |places|
      fte = places.sum(0r, &:fte)
      cost = places.map { |place| @pricing.cost.fetch([ place.person_id, place.unit_id ], {}).transform_values { it * place.fte } }
      capacity = places.uniq { [ it.person_id, it.unit_id ] }.map { |place| @pricing.capacity.fetch([ place.person_id, place.unit_id ], {}) }
      Average.new(cost: average(cost, fte), capacity: average(capacity, fte))
    end
  end

  def average(totals, fte)
    return {} unless fte.positive?

    totals.flat_map(&:to_a).group_by(&:first).transform_values { |pairs| pairs.sum(0r, &:last) / fte }.sort.to_h
  end
end
