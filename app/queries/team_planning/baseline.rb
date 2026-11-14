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
  # @!attribute names [Hash{String => String}] person id => name, empty until joined
  # @!attribute rules [Rules] the rules the organisation follows
  Map = Data.define(:base_on, :known_on, :units, :people, :unassigned_ids, :names, :rules) do
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

  # A person and their facts that day, with each place they hold.
  Member = Data.define(:id, :title, :level, :manager_id, :cost_centre, :site, :country, :fte, :employment_type,
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
  def call = named(structure)

  # @return [Map] by id, with no names
  # @raise [Pundit::NotAuthorizedError] when the caller can't open the plan or see the Org Graph
  def structure
    Pundit.authorize(@context, @plan, :show?, policy_class: PlanPolicy)
    snapshot = OrgGraph::AsOf.new(context: @context, date: @plan.base_on, known_on: @plan.base_on - 1).call

    places = snapshot.memberships.group_by(&:person_id)
    people = snapshot.people.map { |person| person_from(person, places.fetch(person.id, [])) }
    units = snapshot.units.map { Unit.new(**it.to_h.slice(*Unit.members)) }
    Map.new(base_on: snapshot.date, known_on: snapshot.known_on, units:, people:, unassigned_ids: people.select { it.memberships.empty? }.map(&:id), names: {},
            rules: Rules.new(plan_id: @plan.id, defaults: PlanningRuleDefault.values_for(@plan.tenant_id), by_subject: {}))
  end

  # Joins the names of everyone a map names: its people, their managers and
  # the units' owners.
  #
  # @param map [Map]
  # @return [Map]
  def named(map)
    ids = map.people.flat_map { [ it.id, it.manager_id ] } + map.units.flat_map(&:owner_ids)
    map.with(names: ::Person.where(tenant_id: @plan.tenant_id, id: ids.compact.uniq).pluck(:id, :name).to_h)
  end

  private

  def person_from(person, memberships)
    places = memberships.map { Membership.new(**it.to_h.slice(*Membership.members)) }
    Member.new(**person.to_h.slice(*Member.members), memberships: places)
  end
end
