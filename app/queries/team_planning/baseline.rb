# frozen_string_literal: true

# The organisation a plan stands on: its root scenario, which changes
# nothing yet, resolved over {OrgGraph::AsOf} on the plan's base date as
# known at the end of the day before (decision 3). Later Org Graph edits,
# including any made on the base date itself, are drift, never part of it.
#
# {#structure} is ids only, so scenario resolution (story 3.2) can apply a
# plan's changes over it before anything is named. {#call} joins the names
# last, and a forgotten person reads as {Person::FORMER_MEMBER}.
#
# @example
#   map = TeamPlanning::Baseline.new(context:, plan:).call
#   map.unassigned_ids.map { map.name_of(it) }
class TeamPlanning::Baseline
  # The organisation as a plan sees it.
  #
  # @!attribute base_on [Date] the day it shows
  # @!attribute known_on [Date] read as known at the end of this day
  # @!attribute units [Array<Unit>] the live units, by name
  # @!attribute retired_units [Array<Unit>] units a scenario retired; the baseline has none
  # @!attribute successions [Array<Succession>] links a scenario made; the baseline has none
  # @!attribute people [Array<Member>] the people employed that day, by id
  # @!attribute unassigned_ids [Array<String>] the people in no live unit
  # @!attribute positions [Array<Position>] the open positions; the Org Graph has none, so only a plan adds them
  # @!attribute names [Hash{String => String}] person id => name, empty until joined
  # @!attribute rules [Rules] the rules the organisation follows
  # @!attribute unresolved [Array<Unresolved>] the people a plan places who aren't on the map
  Map = Data.define(:base_on, :known_on, :units, :retired_units, :successions, :people, :unassigned_ids, :positions, :names,
                    :rules, :unresolved) do
    def initialize(retired_units: [], successions: [], unresolved: [], **) = super

    # Puts each position's people in its unit, and anyone left in no live
    # unit in Unassigned. A placement in a closed position keeps its
    # position but has no unit.
    #
    # @return [Map]
    def settled
      unit_of = positions.to_h { [ it.id, it.unit_id ] }
      people = self.people.map do |person|
        person.with(memberships: person.memberships.map { it.position_id ? it.with(unit_id: unit_of[it.position_id]) : it })
      end
      live = units.to_set(&:id)
      with(people:, unassigned_ids: people.reject { |person| person.memberships.any? { live.include?(it.unit_id) } }.map(&:id))
    end

    # @return [Hash{String => Array<Array(Member, Membership)>}] position id => each person placed there, with the placement
    def occupants
      people.flat_map { |person| person.memberships.select(&:position_id).map { [ person, it ] } }.group_by { it.last.position_id }
    end

    # The position's FTE less what its people fill: each one's allocation
    # times their FTE, an unknown FTE counting as full time. Below 0 when
    # the position is overfilled.
    #
    # @param position [Position]
    # @param occupants [Array<Array(Member, Membership)>] from {#occupants}
    # @return [Float]
    def open_fte(position, occupants)
      filled = occupants.sum { |person, placement| placement.allocation.to_f * (person.fte || 1).to_f }
      (position.fte.to_f - filled).round(4)
    end

    # Each person's allocations in live units, summed. A total over 1 is
    # never refused, so checks read it. nil means unknown: the HRIS gave a
    # place no allocation, and a check must not read unknown as
    # under-allocated. A place in a closed position or a gone unit counts
    # for nothing.
    #
    # @return [Hash{String => Float, nil}] person id => total
    def allocation_totals
      live = units.to_set(&:id)
      people.to_h do |person|
        allocations = person.memberships.select { live.include?(it.unit_id) }.map(&:allocation)
        [ person.id, allocations.any?(&:nil?) ? nil : allocations.sum(&:to_f).round(4) ]
      end
    end

    # @return [Array<String>] every person id the map uses: its people, their
    #   managers, the units' owners and the people it can't place
    def person_ids
      (people.flat_map { [ it.id, it.manager_id ] } + units.flat_map(&:owner_ids) + unresolved.map(&:person_id)).compact.uniq
    end

    # @param person_id [String]
    # @return [String]
    def name_of(person_id) = names.fetch(person_id, Person::FORMER_MEMBER)

    # A unit follows the nearest unit at or above it that sets the rule, then
    # the plan-wide value. A unit gone from the map takes its rules with it.
    #
    # @param rule [String] a {TeamPlanning::RuleKind.rule_name}
    # @param unit_id [String, nil] nil for the whole plan
    # @return [Hash]
    # @raise [TeamPlanning::Error] for an unknown rule, or a unit not on the map
    def rule(rule, unit_id: nil) = rules.value_of(rule.to_s, along: unit_id ? units_up_from(unit_id) : [])

    private

    def units_up_from(unit_id)
      by_id = units.index_by(&:id)
      raise TeamPlanning::Error, "No such unit" unless by_id.key?(unit_id)

      chain = [ unit_id ]
      while (parent_id = by_id[chain.last].parent_id) && by_id.key?(parent_id) && chain.exclude?(parent_id)
        chain << parent_id
      end
      chain
    end
  end

  # The rules a map follows: each rule's value before the plan sets it, then
  # what the plan's scenarios set, by subject (the plan's id or a unit's).
  #
  # @!attribute plan_id [String] the subject that sets a rule plan-wide
  # @!attribute defaults [Hash{String => Hash}] by rule
  # @!attribute by_subject [Hash{String => Hash{String => Hash}}] subject id => rule => value
  Rules = Data.define(:plan_id, :defaults, :by_subject) do
    # @return [Rules] with the value in place
    def with_rule(subject_id, rule, value) = with(by_subject: by_subject.merge(subject_id => by_subject.fetch(subject_id, {}).merge(rule => value)))

    # @param rule [String]
    # @param along [Array<String>] unit ids, nearest first
    # @return [Hash]
    # @raise [TeamPlanning::Error] for a rule no kind names
    def value_of(rule, along:)
      raise TeamPlanning::Error, "No such rule" unless defaults.key?(rule)

      setter = (along + [ plan_id ]).find { by_subject.fetch(it, {}).key?(rule) }
      setter ? by_subject[setter][rule] : defaults[rule]
    end
  end

  # A live unit. `parent_id` is nil at the root.
  Unit = Data.define(:id, :name, :parent_id, :level_id, :owner_ids)

  # Units that carry on from others: a split, a merge or a replacement.
  Succession = Data.define(:id, :predecessor_ids, :successor_ids)

  # A person and their facts that day, with each place they hold.
  Member = Data.define(:id, :title, :level, :manager_id, :cost_centre, :site, :country, :fte, :employment_type,
                       :memberships)

  # A person's place in a unit, or in a position. A position's place takes
  # the position's unit when the map settles, and none once it closes.
  # `allocation` is nil when the HRIS gave none.
  Membership = Data.define(:unit_id, :allocation, :role, :position_id) do
    def initialize(position_id: nil, **) = super
  end

  # Someone a plan places who isn't on the map, so the placement waits:
  # `why` is "joined after the base date" (updating the plan's base date
  # brings them in) or "has left".
  Unresolved = Data.define(:person_id, :why)
  Unresolved::JOINED_LATER = "joined after the base date"
  Unresolved::LEFT = "has left"

  # An open position. Its role and level names are nil until joined, and stay
  # nil for a role or level the framework no longer has.
  Position = Data.define(:id, :role_id, :level_id, :unit_id, :fte, :basis, :role_name, :level_name) do
    # @param basis [String]
    # @return [String] "committed" for a backfill, "planned" for a new position
    def self.budget_of(basis) = basis == "backfill" ? "committed" : "planned"

    # @return [String] see {.budget_of}
    def budget = self.class.budget_of(basis)
  end

  # @param context [AuthorizationContext]
  # @param plan [TeamPlanningPlan]
  def initialize(context:, plan:)
    @context = context
    @plan = plan
  end

  # @return [Map] with names joined
  # @raise [Pundit::NotAuthorizedError] when the caller can't open the plan or see the Org Graph
  def call = named(structure)

  # @return [Map] by id, with no names
  # @raise [Pundit::NotAuthorizedError] when the caller can't open the plan or see the Org Graph
  def structure
    Pundit.authorize(@context, @plan, :show?, policy_class: PlanPolicy)
    snapshot = OrgGraph::AsOf.new(context: @context, date: @plan.base_on, known_on: @plan.base_on - 1).call

    places = snapshot.memberships.group_by(&:person_id)
    people = snapshot.people.map { |person| person_from(person, places.fetch(person.id, [])) }
    units = snapshot.units.map { Unit.new(**it.to_h.slice(*Unit.members)) }
    Map.new(base_on: snapshot.date, known_on: snapshot.known_on, units:, people:, unassigned_ids: [], positions: [], names: {},
            rules: Rules.new(plan_id: @plan.id, defaults: PlanningRuleDefault.values_for(@plan.tenant_id), by_subject: {})).settled
  end

  # Joins the names of everyone the map names ({Map#person_ids}) and of each
  # position's role and level.
  #
  # @param map [Map]
  # @return [Map]
  def named(map)
    map.with(names: ::Person.where(tenant_id: @plan.tenant_id, id: map.person_ids).pluck(:id, :name).to_h,
             positions: named_positions(map.positions))
  end

  private

  def named_positions(positions)
    return positions if positions.empty?

    roles = FrameworkState::Role.where(tenant_id: @plan.tenant_id, role_id: positions.map(&:role_id).uniq).pluck(:role_id, :name).to_h
    levels = FrameworkState::Level.where(tenant_id: @plan.tenant_id, level_id: positions.map(&:level_id).uniq).pluck(:level_id, :title).to_h
    positions.map { it.with(role_name: roles[it.role_id], level_name: levels[it.level_id]) }
  end

  def person_from(person, memberships)
    places = memberships.map { Membership.new(**it.to_h.slice(*Membership.members)) }
    Member.new(**person.to_h.slice(*Member.members), memberships: places)
  end
end
