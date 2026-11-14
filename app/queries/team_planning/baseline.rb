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
  # @!attribute people [Array<Person>] the people employed that day, by id
  # @!attribute unassigned_ids [Array<String>] the people in no live unit
  # @!attribute names [Hash{String => String}] person id => name, empty until joined
  Map = Data.define(:base_on, :known_on, :units, :people, :unassigned_ids, :names) do
    # @param person_id [String]
    # @return [String]
    def name_of(person_id) = names.fetch(person_id, ::Person::FORMER_MEMBER)
  end

  # A live unit. `parent_id` is nil at the root.
  Unit = Data.define(:id, :name, :parent_id, :level_id, :owner_ids)

  # A person and their facts that day, with each place they hold.
  Person = Data.define(:id, :title, :level, :manager_id, :cost_centre, :site, :country, :fte, :employment_type,
                       :memberships)

  # A person's place in one unit.
  Membership = Data.define(:unit_id, :allocation, :role)

  # @param context [AuthorizationContext]
  # @param plan [TeamPlanningPlan]
  def initialize(context:, plan:)
    @context = context
    @plan = plan
  end

  # @return [Map] with names joined
  # @raise [Pundit::NotAuthorizedError] when the caller can't open the plan or see the Org Graph
  def call
    map = structure
    map.with(names: names_for(map))
  end

  # @return [Map] by id, with no names
  # @raise [Pundit::NotAuthorizedError] when the caller can't open the plan or see the Org Graph
  def structure
    Pundit.authorize(@context, @plan, :show?, policy_class: PlanPolicy)
    snapshot = OrgGraph::AsOf.new(context: @context, date: @plan.base_on, known_on: @plan.base_on - 1).call

    places = snapshot.memberships.group_by(&:person_id)
    people = snapshot.people.map { |person| person_from(person, places.fetch(person.id, [])) }
    units = snapshot.units.map { Unit.new(**it.to_h.slice(*Unit.members)) }
    Map.new(base_on: snapshot.date, known_on: snapshot.known_on, units:, people:, unassigned_ids: people.select { it.memberships.empty? }.map(&:id), names: {})
  end

  private

  def person_from(person, memberships)
    places = memberships.map { Membership.new(**it.to_h.slice(*Membership.members)) }
    Person.new(**person.to_h.slice(*Person.members), memberships: places)
  end

  # Everyone the map names: its people, their managers and the units' owners.
  def names_for(map)
    ids = map.people.flat_map { [ it.id, it.manager_id ] } + map.units.flat_map(&:owner_ids)
    ::Person.where(id: ids.compact.uniq).pluck(:id, :name).to_h
  end
end
