# frozen_string_literal: true

# What a scenario can deliver: each seat priced by the capacity model its
# role chooses ({TeamPlanning::RuleKinds::Capacity}), then summed per unit and
# for the plan. Sums are kept per model, so units and fractions of a person
# never add up to one number.
#
# A seat is a person or an open position, and each of its places is priced on
# its own. A position's place does that position's work, so it takes the
# position's role and level. A person placed straight in a unit takes the role
# and level their title and level resolve to on the map, through the tenant's
# title mapping (as the HRIS sync resolves them), never through today's
# framework assignment, which would mix dates.
#
# A place whose role no model covers counts nowhere and is listed as
# unclassified, with why. Figures stay exact Rationals.
#
# @example
#   report = TeamPlanning::Capacity.new(context:, plan:, scenario_id:).call
#   report.totals # => { "per_fte" => (23/2) }
class TeamPlanning::Capacity
  RULE = TeamPlanning::RuleKinds::Capacity

  # Why a place counts nowhere.
  REASONS = {
    "no_title" => "The person has no title",
    "unmapped_title" => "The person's title maps to no role",
    "unknown_role" => "The role isn't in the framework",
    "no_model" => "No capacity model is chosen for the role or its family",
    "unknown_model" => "The chosen capacity model isn't available"
  }.freeze

  TITLE_REASONS = {
    Integrations::HrisPersonRow::STATUS_NO_TITLE => "no_title",
    Integrations::HrisPersonRow::STATUS_UNMAPPED => "unmapped_title",
    Integrations::HrisPersonRow::STATUS_MISSING_ROLE => "unknown_role"
  }.freeze

  # @!attribute map [TeamPlanning::Baseline::Map] the resolved scenario, named
  # @!attribute seats [Array<Seat>] people by id, then positions by id
  # @!attribute units [Hash{String => Hash{String => Rational}}] unit id => model => total
  # @!attribute totals [Hash{String => Rational}] model => total
  Report = Data.define(:map, :seats, :units, :totals) do
    # @return [Array<Array(Seat, Place)>] each place that counts nowhere, with its seat
    def unclassified = seats.flat_map { |seat| seat.places.select(&:unclassified?).map { [ seat, it ] } }
  end

  # @!attribute seat [TeamPlanning::CapacityModel::Seat]
  # @!attribute places [Array<Place>] in the seat's order
  Seat = Data.define(:seat, :places)

  # @!attribute place [TeamPlanning::CapacityModel::Place, nil] nil when the person's role resolves to none
  # @!attribute unit_id [String, nil]
  # @!attribute model [String, nil] the model chosen
  # @!attribute chosen_for [String, nil] "role" or "family"
  # @!attribute figure [TeamPlanning::CapacityModel::Figure, nil] nil when unclassified
  # @!attribute reason [String, nil] a {REASONS} key when unclassified
  Place = Data.define(:place, :unit_id, :model, :chosen_for, :figure, :reason) do
    # @return [Boolean]
    def unclassified? = reason.present?
  end

  # @param context [AuthorizationContext]
  # @param plan [TeamPlanningPlan]
  # @param scenario_id [String] the plan's id for the root
  # @param repository [TeamPlanning::Repository]
  def initialize(context:, plan:, scenario_id:, repository: TeamPlanning::Repository.new)
    @resolution = TeamPlanning::Resolution.new(context:, plan:, scenario_id:, repository:)
    @plan = plan
  end

  # @return [Report]
  # @raise [Pundit::NotAuthorizedError] when the caller can't open the plan or see the Org Graph
  # @raise [TeamPlanning::Error] for a scenario the plan doesn't have
  def call
    map = @resolution.call
    seats = (map.people.map { person_seat(it) } + map.positions.sort_by(&:id).map { position_seat(it) })
    families = family_ids(seats)
    priced = seats.map { |seat, places| Seat.new(seat:, places: places.map { price(map, seat, it, families) }) }
    Report.new(map:, seats: priced, **sums(priced))
  end

  private

  def person_seat(member)
    target = titles.target(member.title, Integer(member.level, exception: false))
    role_id = target.role&.role_id
    level_id = target.level&.level_id
    reason = TITLE_REASONS.fetch(target.status, nil) unless role_id
    places = member.memberships.map { [ it.unit_id, exact(it.allocation) ] }.presence || [ [ nil, 1r ] ]

    fte = member.fte.nil? ? 1r : exact(member.fte)
    seat_places = places.map { |unit_id, allocation| role_id && TeamPlanning::CapacityModel::Place.new(unit_id:, allocation:, role_id:, level_id:) }
    seat = TeamPlanning::CapacityModel::Seat.new(id: member.id, kind: "person", fte:, fte_known: !member.fte.nil?, places: seat_places.compact)
    [ seat, places.zip(seat_places).map { |(unit_id, _), place| [ unit_id, place, reason ] } ]
  end

  def position_seat(position)
    place = TeamPlanning::CapacityModel::Place.new(unit_id: position.unit_id, allocation: 1r, role_id: position.role_id, level_id: position.level_id)
    seat = TeamPlanning::CapacityModel::Seat.new(id: position.id, kind: "position", fte: exact(position.fte), fte_known: true, places: [ place ])
    [ seat, [ [ position.unit_id, place, nil ] ] ]
  end

  def price(map, seat, (unit_id, place, reason), families)
    return Place.new(place: nil, unit_id:, model: nil, chosen_for: nil, figure: nil, reason:) unless place
    return Place.new(place:, unit_id:, model: nil, chosen_for: nil, figure: nil, reason: "unknown_role") unless families.key?(place.role_id)

    choice = RULE.choice_for(rule_at(map, unit_id), role_id: place.role_id, family_id: families[place.role_id])
    return Place.new(place:, unit_id:, model: nil, chosen_for: nil, figure: nil, reason: "no_model") unless choice

    model, chosen_for = choice.values_at("model", "chosen_for")
    return Place.new(place:, unit_id:, model:, chosen_for:, figure: nil, reason: "unknown_model") unless TeamPlanning::CapacityModels.registered?(model)

    figure = TeamPlanning::CapacityModels.fetch(model).capacity_of(seat, place:, params: choice["params"], map:)
    Place.new(place:, unit_id:, model:, chosen_for:, figure:, reason: nil)
  end

  # A unit the map no longer holds takes its rules with it, so its seats
  # follow the plan-wide choice.
  def rule_at(map, unit_id)
    on_map = unit_id && map.units.any? { it.id == unit_id }
    map.rule(RULE.rule_name, unit_id: on_map ? unit_id : nil)
  end

  def sums(seats)
    priced = seats.flat_map(&:places).reject(&:unclassified?)
    units = priced.select(&:unit_id).group_by(&:unit_id).transform_values { total_by_model(it) }
    { units:, totals: total_by_model(priced) }
  end

  def total_by_model(places) = places.group_by(&:model).transform_values { |group| group.sum { it.figure.amount } }.sort.to_h

  def family_ids(seats)
    role_ids = seats.flat_map { |_, places| places.filter_map { it[1]&.role_id } }.uniq
    FrameworkState::Role.where(tenant_id: @plan.tenant_id, role_id: role_ids).pluck(:role_id, :role_family_id).to_h
  end

  def titles = @titles ||= Integrations::HrisTitleResolution.new(@plan.tenant)

  def exact(value) = value.nil? ? 1r : Rational(value.to_s)
end
