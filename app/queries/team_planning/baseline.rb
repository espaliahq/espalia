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
  # @!attribute people [Array<Member>] the people employed that day, by id
  # @!attribute unassigned_ids [Array<String>] the people in no live unit
  # @!attribute positions [Array<Position>] the open positions; the Org Graph has none, so only a plan adds them
  # @!attribute names [Hash{String => String}] person id => name, empty until joined
  Map = Data.define(:base_on, :known_on, :units, :people, :unassigned_ids, :positions, :names) do
    # @param person_id [String]
    # @return [String]
    def name_of(person_id) = names.fetch(person_id, Person::FORMER_MEMBER)
  end

  # A live unit. `parent_id` is nil at the root.
  Unit = Data.define(:id, :name, :parent_id, :level_id, :owner_ids)

  # A person and their facts that day, with each place they hold.
  Member = Data.define(:id, :title, :level, :manager_id, :cost_centre, :site, :country, :fte, :employment_type,
                       :memberships)

  # A person's place in one unit.
  Membership = Data.define(:unit_id, :allocation, :role)

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
    Map.new(base_on: snapshot.date, known_on: snapshot.known_on, units:, people:, unassigned_ids: people.select { it.memberships.empty? }.map(&:id), positions: [], names: {})
  end

  # Joins the names of everyone a map names (its people, their managers and
  # the units' owners) and of each position's role and level.
  #
  # @param map [Map]
  # @return [Map]
  def named(map)
    ids = map.people.flat_map { [ it.id, it.manager_id ] } + map.units.flat_map(&:owner_ids)
    map.with(names: ::Person.where(tenant_id: @plan.tenant_id, id: ids.compact.uniq).pluck(:id, :name).to_h,
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
