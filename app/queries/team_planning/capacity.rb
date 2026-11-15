# frozen_string_literal: true

# What a scenario can deliver: each seat priced by the capacity model its
# role chooses ({TeamPlanning::RuleKinds::Capacity}), then summed per unit and
# for the plan. Sums are kept per model, so units and fractions of a person
# never add up to one number.
#
# A seat is a person, or the FTE a position's occupants leave open, and each
# of its places is priced on its own. A place in a position does that
# position's work, so it takes the position's role and level. A person placed
# straight in a unit takes the role and level their title and level resolve
# to on the map, through the tenant's title mapping (as the HRIS sync
# resolves them), never through today's framework assignment, which would
# mix dates.
#
# A planner's override replaces a priced place's figure, and the working
# ends with it, so a reader sees the calculated figure behind it. An override
# the plan can no longer read, because its person was forgotten, leaves the
# place counting nowhere: falling back to the model would state a figure the
# planner chose to replace. A place that counts nowhere for another reason,
# such as a leaver's, keeps that reason, and is marked overridden so the
# override doesn't vanish.
#
# A place whose role no model covers counts nowhere and is listed as
# unclassified, with why. A place in a unit gone from the map is still
# counted for the plan, under no unit. Figures stay exact Rationals.
#
# @example
#   report = TeamPlanning::Capacity.new(context:, plan:, scenario_id:).call
#   report.totals # => { "per_fte" => (23/2) }
class TeamPlanning::Capacity
  RULE = TeamPlanning::RuleKinds::Capacity
  Model = TeamPlanning::CapacityModel

  # Why a place counts nowhere.
  REASONS = {
    "no_title" => "The person has no title",
    "unmapped_title" => "The person's title maps to no role",
    "unknown_role" => "The role isn't in the framework",
    "closed_position" => "The position this place is in has closed",
    "leaving" => "The person leaves in this step, so a backfill position carries the seat if the plan gives one",
    "no_level" => "The level resolves to none, so the model has nothing to price",
    "no_model" => "No capacity model is chosen for the role or its family",
    "unknown_model" => "The chosen capacity model isn't available",
    "override_unknown" => "A planner overrode this figure, and the override can't be read since the person was forgotten"
  }.freeze

  TITLE_REASONS = {
    Integrations::HrisPersonRow::STATUS_NO_TITLE => "no_title",
    Integrations::HrisPersonRow::STATUS_UNMAPPED => "unmapped_title",
    Integrations::HrisPersonRow::STATUS_MISSING_ROLE => "unknown_role"
  }.freeze

  # One capacity total split by what it measures
  # ([#351](https://github.com/espaliahq/espalia/issues/351)), each a model =>
  # amount hash. Actual is the baseline's capacity; planned is what the plan's
  # changes add or take away, so it can be negative; forecast is what the
  # assumptions add. A part may hold a model at zero that the total doesn't.
  #
  # @!attribute actual [Hash{String => Rational}]
  # @!attribute planned [Hash{String => Rational}]
  # @!attribute forecast [Hash{String => Rational}]
  # @!attribute total [Hash{String => Rational}] the scenario's own plus the forecast
  Parts = Data.define(:actual, :planned, :forecast, :total)

  # A scenario's capacity beside the baseline's, with what its forecast adds.
  #
  # @!attribute report [Report] the scenario's
  # @!attribute baseline [Report, nil] nil when the scenario is the baseline
  # @!attribute forecast [Array<TeamPlanning::Forecast::Row>]
  Split = Data.define(:report, :baseline, :forecast) do
    # The baseline is all actual.
    #
    # @param unit_id [String, nil] a live unit of the scenario, or nil for the plan
    # @return [Parts]
    def parts(unit_id = nil)
      pick = ->(report) { unit_id ? report.units.fetch(unit_id, {}) : report.totals }
      scenario = pick.(report)
      return Parts.new(actual: scenario, planned: {}, forecast: {}, total: scenario) unless baseline

      actual = pick.(baseline)
      added = TeamPlanning::Capacity.add(forecast.select { unit_id.nil? || it.unit_id == unit_id }.map(&:capacity))
      planned = (scenario.keys | actual.keys).sort.to_h { [ it, scenario.fetch(it, 0r) - actual.fetch(it, 0r) ] }
      Parts.new(actual:, planned:, forecast: added, total: TeamPlanning::Capacity.add([ scenario, added ]))
    end
  end

  # @param amounts [Array<Hash{String => Rational}>] model => amount
  # @return [Hash{String => Rational}] summed per model, by model
  def self.add(amounts) = amounts.flat_map(&:to_a).group_by(&:first).transform_values { |pairs| pairs.sum(0r) { Rational(it.last) } }.sort.to_h

  # @param context [AuthorizationContext]
  # @param plan [TeamPlanningPlan]
  # @param scenario_id [String] the plan's id for the baseline
  # @param repository [TeamPlanning::Repository]
  # @return [Split]
  # @raise [Pundit::NotAuthorizedError] when the caller can't open the plan or see the Org Graph
  # @raise [TeamPlanning::Error] for a scenario the plan doesn't have
  def self.split(context:, plan:, scenario_id:, repository: TeamPlanning::Repository.new)
    aggregate = repository.load_plan(plan.id)
    base = TeamPlanning::Baseline.new(context:, plan:).structure
    price = lambda do |id|
      resolution = TeamPlanning::Resolution.new(context:, plan:, scenario_id: id, repository:, base:)
      new(context:, plan:, scenario_id: id, repository:, resolution:).report_for(resolution.call(aggregate))
    end
    report = price.(scenario_id)
    baseline = price.(plan.id) unless scenario_id == plan.id
    Split.new(report:, baseline:, forecast: TeamPlanning::Forecast.new(aggregate:, scenario_id:, map: report.map, pricing: report.pricing).rows)
  end

  # @!attribute map [TeamPlanning::Baseline::Map] the resolved scenario, named
  # @!attribute seats [Array<Seat>] people by id, then positions with FTE left open, by id
  # @!attribute units [Hash{String => Hash{String => Rational}}] live unit id => model => total
  # @!attribute totals [Hash{String => Rational}] model => total
  Report = Data.define(:map, :seats, :units, :totals) do
    # @return [Array<Array(Seat, Place)>] each place that counts nowhere, with its seat
    def unclassified = seats.flat_map { |seat| seat.places.select(&:unclassified?).map { [ seat, it ] } }

    # What each person's places in a unit deliver per FTE, so a forecast
    # takes away what an empty seat would have delivered.
    #
    # @return [TeamPlanning::Forecast::Pricing]
    def pricing
      live = map.units.to_set(&:id)
      places = seats.select { it.seat.kind == "person" }.flat_map do |seat|
        seat.places.select { it.figure && it.model }.map { [ seat.seat.id, live.include?(it.unit_id) ? it.unit_id : nil, seat.seat.fte * it.place.allocation, it ] }
      end
      TeamPlanning::Forecast::Pricing.new(capacity: places.group_by { it.first(2) }.filter_map do |key, group|
        fte = group.sum(0r) { it[2] }
        [ key, TeamPlanning::Capacity.add(group.map { { it[3].model => it[3].figure.amount } }).transform_values { it / fte } ] if fte.positive?
      end.to_h)
    end

    # @return [Boolean] whether any place has a model chosen, so the plan measures capacity at all
    def measured? = seats.any? { |seat| seat.places.any?(&:model) }

    # @return [Boolean] whether the tenant or plan chooses a model for any role or family, at any unit
    def configured?
      values = [ map.rules.defaults[RULE.rule_name] ] + map.rules.by_subject.values.filter_map { it[RULE.rule_name] }
      values.any? { |value| value.values.any?(&:present?) }
    end
  end

  # @!attribute seat [TeamPlanning::CapacityModel::Seat]
  # @!attribute places [Array<Place>] in the seat's order
  # @!attribute own_level [Boolean] the person's own level prices them, not a position's
  Seat = Data.define(:seat, :places, :own_level) do
    def initialize(own_level: false, **) = super
  end

  # @!attribute place [TeamPlanning::CapacityModel::Place] its role_id is nil when none resolves
  # @!attribute model [String, nil] the model chosen
  # @!attribute chosen_for [String, nil] "role" or "family"
  # @!attribute figure [TeamPlanning::CapacityModel::Figure, nil] nil when unclassified
  # @!attribute reason [String, nil] a {REASONS} key when unclassified
  # @!attribute calculated [TeamPlanning::CapacityModel::Figure, nil] the model's figure, when an override replaced it
  # @!attribute overridden [Boolean] the plan holds an override for the place, applied or not
  Place = Data.define(:place, :model, :chosen_for, :figure, :reason, :calculated, :overridden) do
    def initialize(calculated: nil, overridden: false, **) = super

    # @return [Boolean]
    def unclassified? = reason.present?

    # @return [String, nil]
    def unit_id = place.unit_id
  end

  # @param plan [TeamPlanningPlan]
  # @param context [AuthorizationContext]
  # @param scenario_id [String] the plan's id for the root
  # @param repository [TeamPlanning::Repository]
  # @param resolution [TeamPlanning::Resolution, nil] the scenario's, when the caller already holds one
  def initialize(plan:, context: nil, scenario_id: nil, repository: TeamPlanning::Repository.new, resolution: nil)
    @resolution = resolution || TeamPlanning::Resolution.new(context:, plan:, scenario_id:, repository:)
    @plan = plan
  end

  # @return [Report]
  # @raise [Pundit::NotAuthorizedError] when the caller can't open the plan or see the Org Graph
  # @raise [TeamPlanning::Error] for a scenario the plan doesn't have
  def call = report_for(@resolution.call)

  # Prices a map the caller has already resolved for this scenario.
  #
  # @param map [TeamPlanning::Baseline::Map]
  # @return [Report]
  def report_for(map)
    @map = map
    @positions = @rules = @own_levels = nil
    @overrides = @map.people.to_h { [ it.id, it.capacity_overrides ] }
    @live = @map.units.to_set(&:id)
    people = @map.people.map { person_seat(it) }
    seats = people + open_positions(people)
    families = family_ids(seats)
    @facts = facts(seats)
    priced = seats.map { |seat, reasons| Seat.new(seat:, places: seat.places.zip(reasons).map { |place, reason| price(seat, place, reason, families) },
                                                     own_level: !(@own_levels || {})[seat.id].nil?) }
    Report.new(map: @map, seats: priced, **sums(priced))
  end

  private

  def person_seat(member)
    fte_known = ![ nil, TeamPlanning::Baseline::UNKNOWN ].include?(member.planned_or_own(:fte))
    fte = exact(member.fte_or_one)
    own = member.own_target(titles)
    shares = member.memberships.empty? ? TeamPlanning::Baseline::Membership.shares([ TeamPlanning::Baseline::Membership.new(unit_id: nil, allocation: 1.0, role: nil) ]) : @map.counted_shares(member)
    places, reasons = shares.map { |placement, allocation, known| person_place(placement, allocation, known, own) }.transpose
    reasons = reasons.map { "leaving" } if member.leaving?
    (@own_levels ||= {})[member.id] = own.level&.level_id
    [ Model::Seat.new(id: member.id, kind: "person", fte:, fte_known:, places:), reasons ]
  end

  def person_place(placement, allocation, known, own)
    base = { unit_id: placement.unit_id, allocation:, allocation_known: known, position_id: placement.position_id }
    if placement.position_id
      position = positions[placement.position_id]
      return [ Model::Place.new(**base, role_id: nil, level_id: nil), "closed_position" ] unless position

      [ Model::Place.new(**base, role_id: position.role_id, level_id: position.level_id), nil ]
    else
      [ Model::Place.new(**base, role_id: own.role&.role_id, level_id: own.level&.level_id), (TITLE_REASONS[own.status] unless own.role) ]
    end
  end

  # A position counts only for the FTE its occupants leave open, so a filled
  # one is counted once, through the people in it.
  def open_positions(people)
    filled = Hash.new(0r)
    backfill = @map.people.to_h { [ it.id, it.backfill_id ] }
    people.each { |seat, _| seat.places.each { filled[it.position_id] += seat.fte * it.allocation if it.position_id && it.position_id != backfill[seat.id] } }
    positions.values.sort_by(&:id).filter_map do |position|
      open = exact(position.fte) - filled[position.id]
      next unless open.positive?

      place = Model::Place.new(unit_id: position.unit_id, allocation: 1r, allocation_known: true, role_id: position.role_id,
                               level_id: position.level_id, position_id: position.id)
      [ Model::Seat.new(id: position.id, kind: "position", fte: open, fte_known: true, places: [ place ]), [ nil ] ]
    end
  end

  def price(seat, place, reason, families)
    priced = model_price(seat, place, reason, families)
    override = @overrides.dig(seat.id, place.position_id || place.unit_id)
    return priced unless override
    return priced.with(overridden: true) if priced.unclassified?

    overridden(priced, override)
  end

  def model_price(seat, place, reason, families)
    return Place.new(place:, model: nil, chosen_for: nil, figure: nil, reason:) if reason
    return Place.new(place:, model: nil, chosen_for: nil, figure: nil, reason: "unknown_role") unless families.key?(place.role_id)

    choice = RULE.choice_for(rule_at(place.unit_id), role_id: place.role_id, family_id: families[place.role_id])
    return Place.new(place:, model: nil, chosen_for: nil, figure: nil, reason: "no_model") unless choice

    model, chosen_for = choice.values_at("model", "chosen_for")
    return Place.new(place:, model:, chosen_for:, figure: nil, reason: "unknown_model") unless TeamPlanning::CapacityModels.registered?(model)

    figure = TeamPlanning::CapacityModels.fetch(model).capacity_of(seat, place:, params: choice["params"], map: @map, facts: @facts)
    return Place.new(place:, model:, chosen_for:, figure: nil, reason: figure.reason) if figure.reason

    Place.new(place:, model:, chosen_for:, figure:, reason: nil)
  end

  def overridden(priced, override)
    return priced.with(figure: nil, reason: "override_unknown", calculated: priced.figure, overridden: true) if override.removed?

    calculated = priced.figure
    amount = exact(override.reveal)
    step = Model::Step.new(label: "Planner's override, in place of #{decimal(calculated.amount)}", amount:, op: "=")
    priced.with(figure: Model::Figure.new(amount:, working: calculated.working + [ step ]), calculated:, overridden: true)
  end

  # A unit gone from the map takes its rules with it, so its places follow
  # the plan-wide choice.
  def rule_at(unit_id)
    key = @live.include?(unit_id) ? unit_id : nil
    (@rules ||= {})[key] ||= @map.rule(RULE.rule_name, unit_id: key)
  end

  def sums(seats)
    priced = seats.flat_map(&:places).reject(&:unclassified?)
    units = priced.select { @live.include?(it.unit_id) }.group_by(&:unit_id).transform_values { total_by_model(it) }
    { units:, totals: total_by_model(priced) }
  end

  def total_by_model(places) = places.group_by(&:model).transform_values { |group| group.sum { it.figure.amount } }.sort.to_h

  def family_ids(seats)
    role_ids = seats.flat_map { |seat, _| seat.places.filter_map(&:role_id) }.uniq
    FrameworkState::Role.where(tenant_id: @plan.tenant_id, role_id: role_ids).pluck(:role_id, :role_family_id).to_h
  end

  # A person's level is their own, or failing that the level of the first
  # position they fill.
  def facts(seats)
    level_ids = seats.to_h { |seat, _| [ seat.id, (@own_levels || {})[seat.id] || seat.places.filter_map(&:level_id).first ] }
    every_level = level_ids.values + seats.flat_map { |seat, _| seat.places.map(&:level_id) }
    ordinal_of = FrameworkState::Level.where(tenant_id: @plan.tenant_id, level_id: every_level.compact.uniq).pluck(:level_id, :ordinal).to_h
    Model::Facts.new(level_of: level_ids.transform_values { ordinal_of[it] }.compact, ordinal_of:,
                     role_ids_of: seats.to_h { |seat, _| [ seat.id, seat.places.filter_map(&:role_id).uniq ] },
                     open_fte: seats.select { |seat, _| seat.kind == "position" }.to_h { |seat, _| [ seat.id, seat.fte ] })
  end

  def positions = @positions ||= @map.positions.index_by(&:id)

  def titles = @titles ||= Integrations::HrisTitleResolution.new(@plan.tenant)

  def exact(value) = Rational(value.to_s)

  def decimal(value) = BigDecimal(value, 20).round(4).to_s("F").delete_suffix(".0")
end
