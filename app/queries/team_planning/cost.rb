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
# A member with the see-pay right sees a person priced from the actual pay
# the plan holds for them instead
# ([#317](https://github.com/espaliahq/espalia/issues/317)): made yearly,
# scaled by FTE only when its basis is full_time, by the days held, and with
# on-cost on top. Pay the plan lost with the person's key leaves the seat
# unpriced, as no midpoint stands in for it. Everyone else sees midpoints
# throughout, so the two views total differently. `pay_view` keeps its
# name from before actual pay; each line's `pay_source` says how it was priced.
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
# A scenario also gets a run rate at its end
# ([#334](https://github.com/espaliahq/espalia/issues/334)): every seat it
# holds on its last day, each priced for a full year, beside Today's seats
# priced on that same day, so a move in exchange rates never reads as the
# plan's change. Its forecast part is each forecast row's headcount still
# changed that day, a year of it at the row's own average, which for
# attrition is the steady share of seats waiting to be filled.
#
# @example
#   report = TeamPlanning::Cost.new(context:, plan:, scenario_id:).call
#   report.scenario.totals # => { "EUR" => (60000/1) }
class TeamPlanning::Cost
  YEAR_DAYS = 365
  NO_UNIT = nil
  NO_REFERENCE = "There is no reference currency to total in"
  PAY_VIEWS = %w[band_ranges band_midpoints].freeze
  UNPRICED = { band: nil, currency: nil, pay_source: nil, basis: nil, hours_per_year: nil, yearly: nil, base: nil, on_cost: nil }.freeze

  # Why a seat is unpriced.
  REASONS = {
    "pay_unknown" => "The plan's pay for the person was lost with their key",
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
  # @!attribute band [PayBand, nil] nil when priced from actual pay
  # @!attribute currency [String, nil]
  # @!attribute pay_source [String, nil] "actual" or "band_midpoint" when priced
  # @!attribute basis [String, nil] for actual pay, "actual" or "full_time"
  # @!attribute fte [Rational]
  # @!attribute fraction [Rational] the part of the seat this place carries
  # @!attribute held [Range<Date>, nil] the days the seat is held; nil for none
  # @!attribute year_days [Integer] the days that make a full year: 365 over a period, the year's own for a run rate
  # @!attribute hours_per_year [Rational, nil] for an hourly band
  # @!attribute yearly [Rational, nil] the band midpoint or actual pay for a year
  # @!attribute base [Rational, nil]
  # @!attribute on_cost [TeamPlanning::OnCostModel::Figure, nil]
  # @!attribute reason [String, nil] a {REASONS} key when unpriced
  Line = Data.define(:seat_id, :kind, :unit_id, :position_id, :cost_centre, :cost_centre_source, :cost_centre_rule, :level_id, :level_source, :band,
                     :currency, :pay_source, :basis, :fte, :fraction, :held, :year_days, :hours_per_year, :yearly, :base, :on_cost, :reason) do
    # @return [Boolean]
    def unpriced? = reason.present?

    # @return [Integer]
    def days = held && held.end >= held.begin ? (held.end - held.begin).to_i + 1 : 0

    # @return [Rational] the part of a full-time year the place covers
    def share = fte * fraction * Rational(days, year_days)

    # @return [Rational] the part of {#yearly} the place costs: actual pay
    #   is already what the person earns, so FTE leaves it alone
    def priced_share = basis == "actual" ? fraction * Rational(days, year_days) : share

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

    # @return [Integer] the seats priced from actual pay
    def actual_pay_seats = lines.reject(&:unpriced?).select { it.pay_source == "actual" }.uniq(&:seat_id).size

    # What each person's places in a unit cost a year per FTE, as this map
    # priced them, so a forecast prices under the same pay view.
    #
    # @return [TeamPlanning::Forecast::Pricing]
    def pricing
      held = lines.select { it.kind == "person" && it.share.positive? }.group_by { [ it.seat_id, it.unit_id ] }
      TeamPlanning::Forecast::Pricing.new(cost: held.filter_map do |key, group|
        share = group.sum(0r, &:share)
        priced = group.reject(&:unpriced?)
        [ key, priced.group_by(&:currency).transform_values { |same| same.sum(0r, &:amount) / share } ] if priced.any?
      end.to_h)
    end
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
  Parts = Data.define(:actual, :planned, :forecast, :total) do
    # @param scenario [Sum] the scenario's priced seats
    # @param baseline [Sum] the baseline's over the same days
    # @param forecast [Sum]
    # @return [Parts]
    def self.of(scenario, baseline, forecast)
      new(actual: baseline, planned: TeamPlanning::Cost.difference(scenario, baseline), forecast:,
          total: TeamPlanning::Cost.plus(scenario, forecast))
    end
  end

  # A scenario's yearly run rate on its last day
  # ([#334](https://github.com/espaliahq/espalia/issues/334)).
  #
  # @!attribute on [Date] the scenario's last day
  # @!attribute scenario [Priced] every seat it holds that day, each for a full year
  # @!attribute baseline [Priced] Today's seats, priced on the same day
  # @!attribute forecast [Forecasted] a year of what the forecast rows still change that day
  RunRate = Data.define(:on, :scenario, :baseline, :forecast)

  # @!attribute basis [String] "period" for a scenario, "run_rate" for Today's year
  # @!attribute period [Range<Date>] the scenario's period, or Today's year
  # @!attribute pay_view [String] a {PAY_VIEWS} entry
  # @!attribute reference_currency [String, nil]
  # @!attribute bands_changed_at [Time, nil] when a pay band last changed; plans reprice live
  # @!attribute scenario [Priced]
  # @!attribute baseline [Priced, nil] nil for a run rate, which nothing stands against
  # @!attribute forecast [Forecasted]
  # @!attribute at_end [RunRate, nil] nil for Today, which is a run rate already
  Report = Data.define(:basis, :period, :pay_view, :reference_currency, :bands_changed_at, :scenario, :baseline, :forecast, :at_end) do
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

      Parts.of(priced, pick.(baseline), pick.(forecast))
    end

    # The run rate at the end, split as {#parts} splits the period's total.
    #
    # @param scope [Symbol] :total, :units, :units_with_below or :cost_centres
    # @param key [String, nil]
    # @return [Parts, nil] nil without a run rate at the end
    def at_end_parts(scope = :total, key = nil)
      return unless at_end

      nothing = TeamPlanning::Cost.nothing(reference_currency)
      pick = ->(figures) { (scope == :total ? figures.total : figures.public_send(scope)[key]) || nothing }
      Parts.of(pick.(at_end.scenario), pick.(at_end.baseline), pick.(at_end.forecast))
    end
  end

  # @param context [AuthorizationContext]
  # @param plan [TeamPlanningPlan]
  # @param scenario_id [String] a scenario, or the plan's id for Today's run rate
  # @param repository [TeamPlanning::Repository]
  # @param base [TeamPlanning::Baseline::Map, nil] the plan's baseline, already
  #   read by a caller pricing several scenarios over the same one
  # @param aggregate [TeamPlanning::PlanAggregate, nil] the plan, already loaded
  # @param steps [Hash{String => TeamPlanning::Forecast::Step}] earlier steps
  #   already priced, which this fills as it prices more
  def initialize(context:, plan:, scenario_id:, repository: TeamPlanning::Repository.new, base: nil, aggregate: nil, steps: {})
    @context = context
    @plan = plan
    @scenario_id = scenario_id
    @repository = repository
    @base = base
    @aggregate = aggregate
    @steps = steps
  end

  # Every scenario of the plan priced, reading the Org Graph and the plan once.
  #
  # @return [Hash{String => Report, TeamPlanning::Error}] by scenario id, Today's
  #   run rate first; a scenario that can't be priced maps to its error
  # @raise [Pundit::NotAuthorizedError] when the caller can't open the plan or see the Org Graph
  def self.every_scenario(context:, plan:, repository: TeamPlanning::Repository.new)
    aggregate = repository.load_plan(plan.id)
    base = TeamPlanning::Baseline.new(context:, plan:).structure
    steps = {}
    [ plan.id, *(aggregate.scenarios.keys - [ plan.id ]) ].index_with do |scenario_id|
      new(context:, plan:, scenario_id:, repository:, base:, aggregate:, steps:).call
    rescue TeamPlanning::Error => e
      e
    end
  end

  # @param at_end [Boolean] false skips the run rate at the scenario's end, for a caller that never reads it
  # @return [Report]
  # @raise [Pundit::NotAuthorizedError] when the caller can't open the plan or see the Org Graph
  # @raise [TeamPlanning::Error] for a scenario the plan doesn't have
  def call(at_end: true)
    aggregate = prepare
    run_rate = @scenario_id == @plan.id
    earlier = TeamPlanning::Forecast.reaching(aggregate, @scenario_id, defaults: @base.rules.defaults).index_with { earlier_step(it) }
    scenario = priced(resolved(@scenario_id))
    @steps[@scenario_id] ||= TeamPlanning::Forecast::Step.new(map: scenario.map, pricing: scenario.pricing) unless run_rate
    rows = TeamPlanning::Forecast.new(aggregate:, scenario_id: @scenario_id, map: scenario.map, pricing: scenario.pricing, earlier:).rows
    forecast = forecasted(rows)
    at_end = (run_rate_at_end(scenario.map, rows) if at_end && !run_rate)
    baseline = priced(at_end ? at_end.baseline.map : resolved(@plan.id)) unless run_rate
    Report.new(basis: run_rate ? "run_rate" : "period", period: @period, pay_view: @actual_pay ? "band_ranges" : "band_midpoints",
               reference_currency: @reference, bands_changed_at: [ @plan.tenant.pay_bands_changed_at, *bands.values.flatten.map(&:updated_at) ].compact.max,
               scenario:, baseline:, forecast:, at_end:)
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

  # This scenario's map and pricing, for a later step that carries what its
  # leavers left empty.
  #
  # @return [TeamPlanning::Forecast::Step]
  def step
    @steps[@scenario_id] ||= prepare.then { priced(resolved(@scenario_id)) }.then { TeamPlanning::Forecast::Step.new(map: it.map, pricing: it.pricing) }
  end

  private

  def prepare
    aggregate = @aggregate ||= @repository.load_plan(@plan.id)
    run_rate = @scenario_id == @plan.id
    raise TeamPlanning::Error, "No such scenario" unless aggregate.scenario?(@scenario_id)

    @period = run_rate ? TeamPlanning::Cost.year_from(aggregate.base_on) : aggregate.period_of(@scenario_id)
    @year_days = run_rate ? @period.count : YEAR_DAYS
    @reference = ReferenceCurrency.where(tenant_id: @plan.tenant_id).first&.currency
    @factors = {}
    @actual_pay = PlanPolicy.new(@context, @plan).see_pay?
    @base ||= TeamPlanning::Baseline.new(context: @context, plan: @plan).structure
    aggregate
  end

  # Each seat held on the last day, for a full year: a one-day period of a
  # one-day year. The forecast is summed while the scenario's units hold.
  def run_rate_at_end(map, rows)
    on = @period.end
    scenario, forecast = on_day(on) { [ priced(map), forecasted(rows, &:run_rate) ] }
    RunRate.new(on:, scenario:, forecast:, baseline: on_day(on) { priced(resolved(@plan.id)) })
  end

  def on_day(day)
    period, year_days = @period, @year_days
    @period, @year_days = day..day, 1
    yield
  ensure
    @period, @year_days = period, year_days
  end

  def resolved(scenario_id)
    resolution = TeamPlanning::Resolution.new(context: @context, plan: @plan, scenario_id:, repository: @repository, base: @base)
    resolution.call(@aggregate)
  end

  # Priced over its own period, so a seat it empties costs what that step priced it at.
  def earlier_step(scenario_id)
    @steps[scenario_id] || self.class.new(context: @context, plan: @plan, scenario_id:, repository: @repository, base: @base,
                                          aggregate: @aggregate, steps: @steps).step
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
    pay = member.plan_data[:pay] if @actual_pay
    unpriced = ("pay_unknown" if pay&.removed?) || ("fte_unknown" unless fte_of(member)) ||
               ("level_unknown" if !pay && member.planned_or_own(:level) == TeamPlanning::Baseline::UNKNOWN)
    own_level_id, own_source = person_level(member)
    away = @map.outside_places(member)
    fractions(places).reject { |placement, _| away.include?(placement) }.map do |placement, fraction|
      position = @positions[placement.position_id]
      level_id, source = own_level_id || !position ? [ own_level_id, own_source ] : [ position.level_id, "position" ]
      line(**seat, **person_cost_centre(member, position), unit_id: live_unit(placement.unit_id), position_id: placement.position_id, level_id:,
                   level_source: level_id && source, country: member.country, fraction:, held:, reason: unpriced,
                   pay: pay && !pay.removed? ? pay.reveal : nil)
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

  def line(country:, reason:, pay: nil, **seat)
    seat[:year_days] = @year_days
    band = PayBand.covering(bands.fetch(seat[:level_id], []), country) if seat[:level_id] && !pay
    reason ||= seat[:level_id] ? ("no_band" unless band) : "no_level" unless pay
    return Line.new(**seat, **UNPRICED, reason:) if reason

    line = pay ? paid(pay, seat) : banded(band, seat)
    base = line.yearly * line.priced_share
    on_cost = TeamPlanning::RuleKinds::OnCost.on_cost_of(rule_at("on_cost", seat[:unit_id]), base:, currency: line.currency,
                                                          country:, share: line.share)
    line.with(base:, on_cost:)
  rescue TeamPlanning::Error
    line.with(base:, reason: "on_cost_refused")
  end

  def banded(band, seat)
    hours = hours_at(seat[:unit_id]) if band.period == "hour"
    Line.new(**seat, **UNPRICED, band:, currency: band.currency, pay_source: "band_midpoint", hours_per_year: hours,
                     yearly: band.yearly(:midpoint, hours_per_year: hours), reason: nil)
  end

  def paid(pay, seat)
    hours = hours_at(seat[:unit_id]) if pay["period"] == "hour"
    Line.new(**seat, **UNPRICED, currency: pay["currency"], pay_source: "actual", basis: pay["basis"], hours_per_year: hours,
                     yearly: PayBand.yearly(exact(pay["amount"]), period: pay["period"], hours_per_year: hours), reason: nil)
  end

  def hours_at(unit_id) = TeamPlanning::RuleKinds::WorkingHours.hours_per_year(rule_at("working_hours", unit_id))

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
  def forecasted(rows, &figure)
    figure ||= :cost.to_proc
    total = ->(some) { forecast_sum(some, figure) }
    units = rows.group_by { live_unit(it.unit_id) }.transform_values(&total)
    Forecasted.new(rows:, total: total.(rows), units:, units_with_below: with_below(units),
                   cost_centres: rows.group_by(&:cost_centre).transform_values(&total))
  end

  def forecast_sum(rows, figure)
    converted(rows.flat_map { figure.(it).to_a }.group_by(&:first).transform_values { |pairs| pairs.sum(0r) { exact(it.last) } })
  end

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
    @factors[[ currency, @period.begin ]] ||= ExchangeRate.factor(from: currency, to: @reference, on: @period.begin)
  rescue ExchangeRate::MissingRate => e
    @factors[[ currency, @period.begin ]] = e.message
  end

  def bands = @bands ||= PayBand.where(tenant_id: @plan.tenant_id).to_a.group_by(&:level_id)

  def titles = @titles ||= Integrations::HrisTitleResolution.new(@plan.tenant)

  def exact(value) = Rational(value.to_s)
end
