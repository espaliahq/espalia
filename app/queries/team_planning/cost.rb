# frozen_string_literal: true

# What a scenario costs over its period, beside the baseline priced over the
# same days ([#288](https://github.com/espaliahq/espalia/issues/288)).
#
# Each seat is priced at the midpoint of the pay band for its level and
# country (the band naming the country, else the any-location band), made
# yearly, scaled by FTE and by the part of a 365-day year it is held, plus
# the on-cost its unit's rule adds. A person is priced at their own level,
# a planned one winning, and at their position's level only when theirs
# resolves to none; the working names which. An open seat is the FTE a
# position's occupants leave, priced at the position's level and the
# any-location band. A seat no band prices is unpriced, with its reason,
# and never counts as zero.
#
# A leaver costs up to their leaving date and their backfill from the day
# after, so the seat is never counted twice. Without a date the step is the
# date: the leaver costs nothing in it.
#
# Figures stay exact Rationals in their band's currency, totalled per
# currency. Each total converts once, to the reference currency at the
# period's start; a missing rate leaves it unconverted and says so. Plans
# reprice live: the report states when the bands last changed.
#
# @example
#   report = TeamPlanning::Cost.new(context:, plan:, scenario_id:).call
#   report.scenario.totals # => { "EUR" => (60000/1) }
class TeamPlanning::Cost
  YEAR_DAYS = 365
  NO_UNIT = nil
  NO_COST_CENTRE = nil
  NO_REFERENCE = "There is no reference currency to total in"

  # Why a seat is unpriced.
  REASONS = {
    "level_unknown" => "The plan's level for the person was lost with their key",
    "fte_unknown" => "The plan's FTE for the person was lost with their key",
    "no_level" => "No level resolves for the seat",
    "no_band" => "No pay band covers the seat's level and country",
    "on_cost_refused" => "The on-cost rule at the seat's unit can't price it, such as a fixed amount in another currency"
  }.freeze

  # Where a seat's level comes from.
  LEVEL_SOURCES = {
    "own" => "the person's level",
    "planned" => "the person's planned level",
    "position" => "the position's level, as the person's resolves to none"
  }.freeze

  # One seat's place, priced.
  #
  # @!attribute seat_id [String] a person's id, or a position's for its open FTE
  # @!attribute kind [String] "person" or "position"
  # @!attribute unit_id [String, nil] nil when the place is in no live unit
  # @!attribute position_id [String, nil]
  # @!attribute cost_centre [String, nil] nil for no cost centre
  # @!attribute level_id [String, nil]
  # @!attribute level_source [String, nil] a {LEVEL_SOURCES} key
  # @!attribute band [PayBand, nil]
  # @!attribute fte [Rational]
  # @!attribute fraction [Rational] the part of the seat this place carries
  # @!attribute held [Range<Date>, nil] the days the seat is held; nil for none
  # @!attribute hours_per_year [Rational, nil] for an hourly band
  # @!attribute yearly [Rational, nil] the band midpoint for a full-time year
  # @!attribute base [Rational, nil]
  # @!attribute on_cost [TeamPlanning::OnCostModel::Figure, nil]
  # @!attribute reason [String, nil] a {REASONS} key when unpriced
  Line = Data.define(:seat_id, :kind, :unit_id, :position_id, :cost_centre, :level_id, :level_source, :band, :fte, :fraction,
                     :held, :hours_per_year, :yearly, :base, :on_cost, :reason) do
    # @return [Boolean]
    def unpriced? = reason.present?

    # @return [String, nil]
    def currency = band&.currency

    # @return [Integer]
    def days = held ? held.count : 0

    # @return [Rational] the part of a full-time year the place covers
    def share = fte * fraction * Rational(days, YEAR_DAYS)

    # @return [Rational, nil] base plus on-cost, nil when unpriced
    def amount = unpriced? ? nil : base + on_cost.amount
  end

  # Money per currency, and the same converted to the reference currency.
  #
  # @!attribute native [Hash{String => Rational}] currency => amount
  # @!attribute converted [Rational, nil] nil when there is no reference currency or a rate is missing
  # @!attribute missing [Array<String>] why a currency didn't convert
  Sum = Data.define(:native, :converted, :missing)

  # One map priced over the period.
  #
  # @!attribute map [TeamPlanning::Baseline::Map]
  # @!attribute lines [Array<Line>]
  # @!attribute total [Sum]
  # @!attribute units [Hash{String, nil => Sum}] each unit's own places, nil for no unit
  # @!attribute units_with_below [Hash{String => Sum}] each live unit and the units below it
  # @!attribute cost_centres [Hash{String, nil => Sum}] nil for no cost centre
  Priced = Data.define(:map, :lines, :total, :units, :units_with_below, :cost_centres) do
    # @return [Array<Line>]
    def unpriced = lines.select(&:unpriced?)
  end

  # @!attribute period [Range<Date>]
  # @!attribute reference_currency [String, nil]
  # @!attribute bands_changed_at [Time, nil] when a pay band last changed; plans reprice live
  # @!attribute scenario [Priced]
  # @!attribute baseline [Priced]
  Report = Data.define(:period, :reference_currency, :bands_changed_at, :scenario, :baseline) do
    # @return [Sum] the scenario's total less the baseline's
    def difference = TeamPlanning::Cost.difference(scenario.total, baseline.total)
  end

  # @param context [AuthorizationContext]
  # @param plan [TeamPlanningPlan]
  # @param scenario_id [String] a scenario, never the root, which has no period
  # @param repository [TeamPlanning::Repository]
  def initialize(context:, plan:, scenario_id:, repository: TeamPlanning::Repository.new)
    @context = context
    @plan = plan
    @scenario_id = scenario_id
    @repository = repository
  end

  # @return [Report]
  # @raise [Pundit::NotAuthorizedError] when the caller can't open the plan or see the Org Graph
  # @raise [TeamPlanning::Error] for the root, or a scenario the plan doesn't have
  def call
    aggregate = @repository.load_plan(@plan.id)
    raise TeamPlanning::Error, "No such scenario" unless aggregate.scenario?(@scenario_id)
    raise TeamPlanning::Error, "The baseline has no period to cost, so cost one of the plan's scenarios" if @scenario_id == @plan.id

    @period = aggregate.period_of(@scenario_id)
    @reference = ReferenceCurrency.where(tenant_id: @plan.tenant_id).first&.currency
    @factors = {}
    scenario = priced(resolved(@scenario_id))
    baseline = priced(resolved(@plan.id))
    Report.new(period: @period, reference_currency: @reference, bands_changed_at: bands.values.flatten.map(&:updated_at).max,
               scenario:, baseline:)
  end

  # @param reference_currency [String, nil]
  # @return [Sum] no money, converted as an empty sum would be
  def self.nothing(reference_currency)
    reference_currency ? Sum.new(native: {}, converted: 0r, missing: []) : Sum.new(native: {}, converted: nil, missing: [ NO_REFERENCE ])
  end

  # @param one [Sum]
  # @param other [Sum]
  # @return [Sum] one less the other, converted only when both are
  def self.difference(one, other)
    native = (one.native.keys | other.native.keys).sort.to_h { [ it, one.native.fetch(it, 0r) - other.native.fetch(it, 0r) ] }
    converted = one.converted - other.converted if one.converted && other.converted
    Sum.new(native:, converted:, missing: (one.missing | other.missing))
  end

  private

  def resolved(scenario_id) = TeamPlanning::Resolution.new(context: @context, plan: @plan, scenario_id:, repository: @repository).call

  def priced(map)
    @map = map
    @live = map.units.to_set(&:id)
    @rules = {}
    @positions = map.positions.index_by(&:id)
    people = map.people.flat_map { person_lines(it) }
    lines = people + open_lines(map)
    Priced.new(map:, lines:, total: sum(lines), units: by(lines, &:unit_id), units_with_below: with_below(lines),
               cost_centres: by(lines, &:cost_centre))
  end

  def person_lines(member)
    places = TeamPlanning::Baseline::Membership.shares(member.memberships)
    held = held_by(member)
    seat = { seat_id: member.id, kind: "person", cost_centre: member.cost_centre.presence, fte: fte_of(member) || 1r }
    unpriced = ("fte_unknown" unless fte_of(member)) || ("level_unknown" if member.planned_or_own(:level) == TeamPlanning::Baseline::UNKNOWN)
    own_level_id, own_source = person_level(member)
    fractions(places).map do |placement, fraction|
      position = @positions[placement.position_id]
      level_id, source = own_level_id || !position ? [ own_level_id, own_source ] : [ position.level_id, "position" ]
      line(**seat, unit_id: live_unit(placement.unit_id), position_id: placement.position_id, level_id:, level_source: level_id && source,
                   country: member.country, fraction:, held:, reason: unpriced)
    end
  end

  # Each place's part of the seat, so the places of a person always add up
  # to the whole seat. A person in no place carries it under no unit.
  def fractions(places)
    weight = places.sum(0r) { it[1] }
    return [ [ TeamPlanning::Baseline::Membership.new(unit_id: nil, allocation: 1, role: nil), 1r ] ] unless weight.positive?

    places.map { |placement, share, _| [ placement, share / weight ] }
  end

  def open_lines(map)
    filled = Hash.new(0r)
    map.people.each do |person|
      TeamPlanning::Baseline::Membership.shares(person.memberships).each do |placement, share, _|
        filled[placement.position_id] += (fte_of(person) || 1r) * share if placement.position_id && placement.position_id != person.backfill_id
      end
    end
    leavers = map.people.select(&:leaving?).group_by(&:backfill_id)
    map.positions.sort_by(&:id).filter_map do |position|
      open = exact(position.fte) - filled[position.id]
      next unless open.positive?

      line(seat_id: position.id, kind: "position", unit_id: live_unit(position.unit_id), position_id: position.id, cost_centre: NO_COST_CENTRE,
           level_id: position.level_id, level_source: nil, country: nil, fte: open, fraction: 1r,
           held: backfill_held(leavers.fetch(position.id, [])), reason: nil)
    end
  end

  def line(country:, reason:, **seat)
    band = PayBand.covering(bands.fetch(seat[:level_id], []), country) if seat[:level_id]
    reason ||= seat[:level_id] ? ("no_band" unless band) : "no_level"
    empty = { band: nil, hours_per_year: nil, yearly: nil, base: nil, on_cost: nil }
    return Line.new(**seat, **empty, reason:) if reason

    hours = TeamPlanning::RuleKinds::WorkingHours.hours_per_year(rule_at("working_hours", seat[:unit_id])) if band.period == "hour"
    yearly = band.yearly(:midpoint, hours_per_year: hours)
    line = Line.new(**seat, band:, hours_per_year: hours, yearly:, base: nil, on_cost: nil, reason: nil)
    base = yearly * line.share
    on_cost = TeamPlanning::RuleKinds::OnCost.on_cost_of(rule_at("on_cost", seat[:unit_id]), base:, currency: band.currency,
                                                          country:, share: line.share)
    line.with(base:, on_cost:)
  rescue TeamPlanning::Error
    line.with(base:, reason: "on_cost_refused")
  end

  def person_level(member)
    level = member.planned_or_own(:level)
    return [ nil, nil ] if level == TeamPlanning::Baseline::UNKNOWN

    [ member.own_target(titles).level&.level_id, member.planned_level? ? "planned" : "own" ]
  end

  # A leaver in this step holds the seat up to their leaving date, and for
  # none of the step without one.
  def held_by(member)
    return @period unless member.leaving?

    last = TeamPlanning::Events::DepartureSet.leaving_date(member.departure[:leaves_on])
    last && (@period.begin..[ last, @period.end ].min)
  end

  # A leaver with no date costs nothing in the step, so their backfill holds
  # all of it, whatever the other leavers' dates.
  def backfill_held(leavers)
    dates = leavers.map { TeamPlanning::Events::DepartureSet.leaving_date(it.departure[:leaves_on]) }
    return @period if dates.empty? || dates.any?(&:nil?)
    return nil if dates.max >= @period.end

    [ dates.max + 1, @period.begin ].max..@period.end
  end

  def fte_of(member)
    fte = member.planned_or_own(:fte)
    return nil if fte == TeamPlanning::Baseline::UNKNOWN

    exact(fte.nil? ? 1 : fte)
  end

  def live_unit(unit_id) = @live.include?(unit_id) ? unit_id : NO_UNIT

  # A unit gone from the map takes its rules with it, so its seats follow
  # the plan-wide value.
  def rule_at(rule, unit_id) = @rules[[ rule, unit_id ]] ||= @map.rule(rule, unit_id: unit_id)

  def by(lines, &key) = lines.group_by(&key).transform_values { sum(it) }

  def with_below(lines)
    children = @map.units.group_by(&:parent_id)
    own = lines.group_by(&:unit_id)
    below = ->(id) { own.fetch(id, []) + children.fetch(id, []).flat_map { below.(it.id) } }
    @map.units.to_h { [ it.id, sum(below.(it.id)) ] }
  end

  def sum(lines)
    native = lines.reject(&:unpriced?).group_by(&:currency).transform_values { |group| group.sum(0r, &:amount) }.sort.to_h
    converted, missing = convert(native)
    Sum.new(native:, converted:, missing:)
  end

  def convert(native)
    return [ nil, [ NO_REFERENCE ] ] unless @reference

    factors = native.keys.index_with { factor(it) }
    missing = factors.values.grep(String)
    return [ nil, missing ] if missing.any?

    [ native.sum(0r) { |currency, amount| amount * factors[currency] }, [] ]
  end

  def factor(currency)
    @factors[currency] ||= ExchangeRate.factor(from: currency, to: @reference, on: @period.begin)
  rescue ExchangeRate::MissingRate => e
    @factors[currency] = e.message
  end

  def bands = @bands ||= PayBand.where(tenant_id: @plan.tenant_id).to_a.group_by(&:level_id)

  def titles = @titles ||= Integrations::HrisTitleResolution.new(@plan.tenant)

  def exact(value) = Rational(value.to_s)
end
