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
# any-location band, under its position's cost centre
# ({TeamPlanning::PositionCostCentres}). A person's seat keeps the person's
# own cost centre, as the cost centre rules never move it; a placeholder
# hire takes their position's. A seat no band prices is unpriced, with its reason,
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
# Today has no period of its own, so it gets a run rate instead: every seat
# it holds priced for the year from the base date to the day before the
# same date a year later, a leap year counting as one full year
# ([#318](https://github.com/espaliahq/espalia/issues/318)). A run rate has
# no baseline to stand against, and is never compared with a period total.
#
# @example
#   report = TeamPlanning::Cost.new(context:, plan:, scenario_id:).call
#   report.scenario.totals # => { "EUR" => (60000/1) }
class TeamPlanning::Cost
  YEAR_DAYS = 365
  NO_UNIT = nil
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
  # @!attribute cost_centre_source [String] a {TeamPlanning::PositionCostCentres::SOURCES} entry
  # @!attribute cost_centre_rule [Integer, nil] the winning cost centre rule's index, for "rule"
  # @!attribute level_id [String, nil]
  # @!attribute level_source [String, nil] a {LEVEL_SOURCES} key
  # @!attribute band [PayBand, nil]
  # @!attribute fte [Rational]
  # @!attribute fraction [Rational] the part of the seat this place carries
  # @!attribute held [Range<Date>, nil] the days the seat is held; nil for none
  # @!attribute year_days [Integer] the days that make a full year: 365 over a period, the year's own for a run rate
  # @!attribute hours_per_year [Rational, nil] for an hourly band
  # @!attribute yearly [Rational, nil] the band midpoint for a full-time year
  # @!attribute base [Rational, nil]
  # @!attribute on_cost [TeamPlanning::OnCostModel::Figure, nil]
  # @!attribute reason [String, nil] a {REASONS} key when unpriced
  Line = Data.define(:seat_id, :kind, :unit_id, :position_id, :cost_centre, :cost_centre_source, :cost_centre_rule, :level_id, :level_source, :band, :fte, :fraction,
                     :held, :year_days, :hours_per_year, :yearly, :base, :on_cost, :reason) do
    # @return [Boolean]
    def unpriced? = reason.present?

    # @return [String, nil]
    def currency = band&.currency

    # @return [Integer]
    def days = held && held.end >= held.begin ? (held.end - held.begin).to_i + 1 : 0

    # @return [Rational] the part of a full-time year the place covers
    def share = fte * fraction * Rational(days, year_days)

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

  # What the forecast assumptions add to the scenario
  # ([#351](https://github.com/espaliahq/espalia/issues/351)), summed as a
  # {Priced} map's lines are.
  #
  # @!attribute rows [Array<TeamPlanning::Forecast::Row>]
  # @!attribute total [Sum]
  # @!attribute units [Hash{String, nil => Sum}]
  # @!attribute units_with_below [Hash{String => Sum}]
  # @!attribute cost_centres [Hash{String, nil => Sum}]
  Forecasted = Data.define(:rows, :total, :units, :units_with_below, :cost_centres)

  # One total split by what it measures. Actual is the baseline's figure over
  # the same days; planned is what the plan's changes add or take away, so it
  # can be negative; forecast is what the assumptions add. A part may hold a
  # currency at zero that the total doesn't name.
  #
  # @!attribute actual [Sum]
  # @!attribute planned [Sum]
  # @!attribute forecast [Sum]
  # @!attribute total [Sum] the scenario's priced seats plus the forecast: the three parts' sum
  Parts = Data.define(:actual, :planned, :forecast, :total)

  # @!attribute basis [String] "period" for a scenario, "run_rate" for Today's year
  # @!attribute period [Range<Date>] the scenario's period, or Today's year
  # @!attribute reference_currency [String, nil]
  # @!attribute bands_changed_at [Time, nil] when a pay band last changed; plans reprice live
  # @!attribute scenario [Priced]
  # @!attribute baseline [Priced, nil] nil for a run rate, which nothing stands against
  # @!attribute forecast [Forecasted]
  Report = Data.define(:basis, :period, :reference_currency, :bands_changed_at, :scenario, :baseline, :forecast) do
    # @return [Boolean]
    def run_rate? = basis == "run_rate"

    # @return [Sum, nil] the total less the baseline's; nil for a run rate
    def difference = baseline && TeamPlanning::Cost.difference(parts.total, baseline.total)

    # Today's run rate is all actual.
    #
    # @param scope [Symbol] :total, :units, :units_with_below or :cost_centres
    # @param key [String, nil] the unit or cost centre, nil for none
    # @return [Parts]
    def parts(scope = :total, key = nil)
      nothing = TeamPlanning::Cost.nothing(reference_currency)
      pick = ->(figures) { (scope == :total ? figures&.total : figures&.public_send(scope)&.[](key)) || nothing }
      priced = pick.(scenario)
      return Parts.new(actual: priced, planned: nothing, forecast: nothing, total: priced) if run_rate?

      actual = pick.(baseline)
      forecast = pick.(self.forecast)
      Parts.new(actual:, planned: TeamPlanning::Cost.difference(priced, actual), forecast:, total: TeamPlanning::Cost.plus(priced, forecast))
    end
  end

  # @param context [AuthorizationContext]
  # @param plan [TeamPlanningPlan]
  # @param scenario_id [String] a scenario, or the plan's id for Today's run rate
  # @param repository [TeamPlanning::Repository]
  # @param base [TeamPlanning::Baseline::Map, nil] the plan's baseline, already
  #   read by a caller pricing several scenarios over the same one
  # @param aggregate [TeamPlanning::PlanAggregate, nil] the plan, already loaded
  def initialize(context:, plan:, scenario_id:, repository: TeamPlanning::Repository.new, base: nil, aggregate: nil)
    @context = context
    @plan = plan
    @scenario_id = scenario_id
    @repository = repository
    @base = base
    @aggregate = aggregate
  end

  # Every scenario of the plan priced, reading the Org Graph and the plan once.
  #
  # @return [Hash{String => Report, TeamPlanning::Error}] by scenario id, Today's
  #   run rate first; a scenario that can't be priced maps to its error
  # @raise [Pundit::NotAuthorizedError] when the caller can't open the plan or see the Org Graph
  def self.every_scenario(context:, plan:, repository: TeamPlanning::Repository.new)
    aggregate = repository.load_plan(plan.id)
    base = TeamPlanning::Baseline.new(context:, plan:).structure
    [ plan.id, *(aggregate.scenarios.keys - [ plan.id ]) ].index_with do |scenario_id|
      new(context:, plan:, scenario_id:, repository:, base:, aggregate:).call
    rescue TeamPlanning::Error => e
      e
    end
  end

  # @return [Report]
  # @raise [Pundit::NotAuthorizedError] when the caller can't open the plan or see the Org Graph
  # @raise [TeamPlanning::Error] for a scenario the plan doesn't have
  def call
    aggregate = @aggregate ||= @repository.load_plan(@plan.id)
    run_rate = @scenario_id == @plan.id
    raise TeamPlanning::Error, "No such scenario" unless aggregate.scenario?(@scenario_id)

    @period = run_rate ? TeamPlanning::Cost.year_from(aggregate.base_on) : aggregate.period_of(@scenario_id)
    @year_days = run_rate ? @period.count : YEAR_DAYS
    @reference = ReferenceCurrency.where(tenant_id: @plan.tenant_id).first&.currency
    @factors = {}
    @base ||= TeamPlanning::Baseline.new(context: @context, plan: @plan).structure
    scenario = priced(resolved(@scenario_id))
    forecast = forecasted(TeamPlanning::Forecast.new(aggregate:, scenario_id: @scenario_id, map: scenario.map).rows)
    baseline = priced(resolved(@plan.id)) unless run_rate
    Report.new(basis: run_rate ? "run_rate" : "period", period: @period, reference_currency: @reference, bands_changed_at: [ @plan.tenant.pay_bands_changed_at, *bands.values.flatten.map(&:updated_at) ].compact.max,
               scenario:, baseline:, forecast:)
  end

  # @param starts_on [Date]
  # @return [Range<Date>] to the day before the same date a year later; from
  #   29 February, to 28 February, as the next year has no 29th
  def self.year_from(starts_on)
    following = starts_on.next_year
    starts_on..(following.day == starts_on.day ? following - 1 : following)
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

  # @param one [Sum]
  # @param other [Sum]
  # @return [Sum] both together, converted only when both are
  def self.plus(one, other)
    Sum.new(native: one.native.merge(other.native) { |_, a, b| a + b }.sort.to_h,
            converted: one.converted && other.converted && (one.converted + other.converted), missing: one.missing | other.missing)
  end

  private

  def resolved(scenario_id)
    resolution = TeamPlanning::Resolution.new(context: @context, plan: @plan, scenario_id:, repository: @repository, base: @base)
    resolution.call(@aggregate)
  end

  def priced(map)
    @map = map
    @live = map.units.to_set(&:id)
    @rules = {}
    @positions = map.positions.index_by(&:id)
    @cost_centres = TeamPlanning::PositionCostCentres.new(map, tenant_id: @plan.tenant_id)
    people = map.people.flat_map { person_lines(it) }
    lines = people + open_lines(map)
    units = by(lines, &:unit_id)
    Priced.new(map:, lines:, total: sum(lines), units:, units_with_below: with_below(units), cost_centres: by(lines, &:cost_centre))
  end

  def person_lines(member)
    places = TeamPlanning::Baseline::Membership.shares(member.memberships)
    held = held_by(member)
    seat = { seat_id: member.id, kind: "person", fte: fte_of(member) || 1r }
    unpriced = ("fte_unknown" unless fte_of(member)) || ("level_unknown" if member.planned_or_own(:level) == TeamPlanning::Baseline::UNKNOWN)
    own_level_id, own_source = person_level(member)
    fractions(places).map do |placement, fraction|
      position = @positions[placement.position_id]
      level_id, source = own_level_id || !position ? [ own_level_id, own_source ] : [ position.level_id, "position" ]
      line(**seat, **person_cost_centre(member, position), unit_id: live_unit(placement.unit_id), position_id: placement.position_id, level_id:, level_source: level_id && source,
                   country: member.country, fraction:, held:, reason: unpriced)
    end
  end

  # A person keeps their own cost centre, as the cost centre rules never move
  # it. A placeholder hire has none of their own, so takes their position's.
  def person_cost_centre(member, position)
    resolved = if member.placeholder?
      position ? @cost_centres.of(position) : TeamPlanning::PositionCostCentres::NONE
    else
      cost_centre = member.cost_centre.presence
      TeamPlanning::PositionCostCentres::Resolved.new(cost_centre:, source: cost_centre ? "person" : "none")
    end
    { cost_centre: resolved.cost_centre, cost_centre_source: resolved.source, cost_centre_rule: resolved.rule_index }
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

      cost_centre = @cost_centres.of(position)
      openings(open, leavers.fetch(position.id, [])).map do |fte, held|
        line(seat_id: position.id, kind: "position", unit_id: live_unit(position.unit_id), position_id: position.id,
             cost_centre: cost_centre.cost_centre, cost_centre_source: cost_centre.source, cost_centre_rule: cost_centre.rule_index,
             level_id: position.level_id, level_source: nil, country: nil, fte:, fraction: 1r, held:, reason: nil)
      end
    end.flatten
  end

  def line(country:, reason:, **seat)
    band = PayBand.covering(bands.fetch(seat[:level_id], []), country) if seat[:level_id]
    reason ||= seat[:level_id] ? ("no_band" unless band) : "no_level"
    empty = { band: nil, hours_per_year: nil, yearly: nil, base: nil, on_cost: nil }
    return Line.new(**seat, year_days: @year_days, **empty, reason:) if reason

    hours = TeamPlanning::RuleKinds::WorkingHours.hours_per_year(rule_at("working_hours", seat[:unit_id])) if band.period == "hour"
    yearly = band.yearly(:midpoint, hours_per_year: hours)
    line = Line.new(**seat, year_days: @year_days, band:, hours_per_year: hours, yearly:, base: nil, on_cost: nil, reason: nil)
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

  # A backfill opens a leaver's FTE the day after they leave, or for the
  # whole step when they have no date, as they then cost none of it. The
  # earliest leaver is replaced first, and FTE no leaver opens is held all
  # step like any open seat. Each opening is its own line, so no seat is
  # ever held by a leaver and their backfill at once.
  def openings(open, leavers)
    dated = leavers.map { [ fte_of(it) || 1r, TeamPlanning::Events::DepartureSet.leaving_date(it.departure[:leaves_on]) ] }
    held = dated.sort_by { |_, last| last || Date.new(0) }.filter_map do |fte, last|
      fte = [ fte, open ].min
      next unless fte.positive?

      open -= fte
      [ fte, backfill_held(last) ]
    end
    open.positive? ? held << [ open, @period ] : held
  end

  def backfill_held(last)
    return @period unless last
    return nil if last >= @period.end

    [ last + 1, @period.begin ].max..@period.end
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

  # Each unit's own sum plus its children's, each child's folded in once.
  def with_below(units)
    children = @map.units.group_by(&:parent_id)
    totals = {}
    fold = ->(id) { totals[id] ||= children.fetch(id, []).reduce(units[id] || self.class.nothing(@reference)) { |sum, child| plus(sum, fold.(child.id)) } }
    @map.units.each { fold.(it.id) }
    totals
  end

  def plus(one, other) = self.class.plus(one, other)

  def sum(lines) = converted(lines.reject(&:unpriced?).group_by(&:currency).transform_values { |group| group.sum(0r, &:amount) })

  # Called straight after the scenario is priced, so its units hold.
  def forecasted(rows)
    units = rows.group_by { live_unit(it.unit_id) }.transform_values { forecast_sum(it) }
    Forecasted.new(rows:, total: forecast_sum(rows), units:, units_with_below: with_below(units),
                   cost_centres: rows.group_by(&:cost_centre).transform_values { forecast_sum(it) })
  end

  def forecast_sum(rows) = converted(rows.flat_map { it.cost.to_a }.group_by(&:first).transform_values { |pairs| pairs.sum(0r) { exact(it.last) } })

  def converted(native)
    native = native.sort.to_h
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
