# frozen_string_literal: true

# Event-sourced aggregate for one plan.
#
# One RES stream per plan: tenant-{tenant_id}/Plan-{plan_id}. A plan stands on
# the Org Graph as of its base date, read as known at the end of the day
# before (decision 3 in docs/team-planning/team-planning-plan.md). Once
# deleted, it takes no more changes.
#
# Its members are editors or viewers, and its creator is its first editor. A
# plan always keeps an editor: the last one can neither leave nor become a
# viewer.
#
# Its scenarios form a tree under the root, the baseline, which shares the
# plan's id, stands on the base date and has no period. A `then` scenario is
# the next step after its parent; an `instead` scenario is an alternative over
# its parent's period. Only a `then` scenario's end is held: every start, and
# an alternative's whole period, follows from the tree, so the periods along
# any path from the root stay contiguous.
#
# Each scenario holds its changes ({TeamPlanning::Events::Change}) in the order
# made. A scenario resolves along its {#resolution_chain}, so an alternative is
# its parent plus its own differences, while on the timeline
# ({#timeline_path}) it stands in its parent's place.
class TeamPlanning::PlanAggregate
  # Every change kind lands in one handler, so a new kind needs no `on` here.
  class ApplyStrategy < AggregateRoot::DefaultApplyStrategy
    def call(aggregate, event)
      return aggregate.send(:record_change, event) if event.is_a?(TeamPlanning::Events::Change)

      super
    end
  end

  include AggregateRoot.with(strategy: -> { ApplyStrategy.new })

  NAME_LIMIT = 120
  ROLES = %w[editor viewer].freeze
  RELATIONS = %w[then instead].freeze

  # A scenario as the plan holds it. `ends_on` is held only for a `then`
  # scenario; {#period_of} works out every period.
  Scenario = Data.define(:id, :parent_id, :relation, :name, :ends_on)

  # @return [String, nil]
  attr_reader :plan_id, :name, :base_on, :created_by_id

  def initialize
    @members = {}
    @scenarios = {}
    @removed_scenario_ids = Set.new
    @changes = {}
  end

  # Opens the plan.
  #
  # @param plan_id [String] UUID minted by the caller
  # @param name [String]
  # @param base_on [Date, String] the day the plan stands on
  # @param created_by_id [String] person_id of the creator
  # @raise [TeamPlanning::Error] if the plan exists, or the name is blank or too long
  # @raise [Date::Error] unless base_on is a Date or a YYYY-MM-DD string
  def create(plan_id, name:, base_on:, created_by_id:)
    raise TeamPlanning::Error, "This plan already exists" if @plan_id

    apply(TeamPlanning::Events::PlanCreated.new(data: {
      plan_id: plan_id,
      name: require_name(name),
      base_on: require_date(base_on).iso8601,
      created_by_id: created_by_id
    }))
  end

  # Renames the plan. The same name writes nothing.
  #
  # @param name [String]
  # @param renamed_by_id [String]
  # @raise [TeamPlanning::Error] if the plan is gone, or the name is blank or too long
  def rename(name, renamed_by_id:)
    ensure_open!
    name = require_name(name)
    return if name == @name

    apply(TeamPlanning::Events::PlanRenamed.new(data: {
      plan_id: @plan_id, name: name, previous_name: @name, renamed_by_id: renamed_by_id
    }))
  end

  # Deletes the plan.
  #
  # @param deleted_by_id [String]
  # @param reason [String, nil] why, when a tenant admin deletes a frozen plan
  # @raise [TeamPlanning::Error] if the plan is gone
  def delete(deleted_by_id:, reason: nil)
    ensure_open!

    apply(TeamPlanning::Events::PlanDeleted.new(data: {
      plan_id: @plan_id, deleted_by_id: deleted_by_id, reason: reason.to_s.squish.presence
    }.compact))
  end

  # Makes someone a member, or gives a member another role. The role they
  # already have writes nothing.
  #
  # @param person_id [String]
  # @param role [String] "editor" or "viewer"
  # @param added_by_id [String]
  # @raise [TeamPlanning::Error] if the plan is gone, the role is unknown, or
  #   this would leave the plan without an editor
  def add_member(person_id, role:, added_by_id:)
    ensure_open!
    role = role.to_s
    raise TeamPlanning::Error, "A member is an editor or a viewer" unless ROLES.include?(role)
    return if @members[person_id] == role

    ensure_editor_remains!(person_id) if role == "viewer"
    apply(TeamPlanning::Events::PlanMemberAdded.new(data: {
      plan_id: @plan_id, person_id: person_id, role: role, added_by_id: added_by_id
    }))
  end

  # Takes someone off the plan, or lets them leave it.
  #
  # @param person_id [String]
  # @param removed_by_id [String]
  # @raise [TeamPlanning::Error] if the plan is gone, they aren't a member, or
  #   they are its last editor
  def remove_member(person_id, removed_by_id:)
    ensure_open!
    raise TeamPlanning::Error, "They aren't a member of this plan" unless member?(person_id)

    ensure_editor_remains!(person_id)
    apply(TeamPlanning::Events::PlanMemberRemoved.new(data: {
      plan_id: @plan_id, person_id: person_id, removed_by_id: removed_by_id
    }))
  end

  # Forks a scenario from another in the plan, or from the root.
  #
  # @param scenario_id [String] UUID minted by the caller
  # @param parent_id [String] a live scenario, or the plan's id for the root
  # @param relation [String] "then" or "instead"
  # @param name [String]
  # @param ends_on [Date, String, nil] required for `then`; for `instead`, if
  #   given, its parent's end
  # @param starts_on [Date, String, nil] if given, the start the tree implies
  # @param forked_by_id [String]
  # @raise [TeamPlanning::Error] if the plan is gone, the id is taken, the
  #   parent unknown, or the period doesn't fit the tree
  # @raise [Date::Error] for a date that isn't YYYY-MM-DD
  def fork_scenario(scenario_id, parent_id:, relation:, name:, forked_by_id:, ends_on: nil, starts_on: nil)
    ensure_open!
    raise TeamPlanning::Error, "This plan already has that scenario" if scenario_id_taken?(scenario_id)

    relation = relation.to_s
    raise TeamPlanning::Error, "A scenario forks as then or instead" unless RELATIONS.include?(relation)

    period = forked_period(live_scenario!(parent_id), relation, starts_on:, ends_on:)
    apply(TeamPlanning::Events::ScenarioForked.new(data: {
      plan_id: @plan_id, scenario_id: scenario_id, parent_id: parent_id, relation: relation,
      name: require_name(name, "scenario"), starts_on: period.begin.iso8601, ends_on: period.end.iso8601,
      forked_by_id: forked_by_id
    }))
  end

  # Moves a `then` scenario's end. Its start stays where the tree puts it, and
  # the steps after it start from the new end. The same end writes nothing.
  #
  # @param scenario_id [String]
  # @param ends_on [Date, String]
  # @param set_by_id [String]
  # @raise [TeamPlanning::Error] if the plan is gone, the scenario unknown, the
  #   root or an alternative, or if the move leaves any scenario ending before
  #   it starts
  # @raise [Date::Error] for a date that isn't YYYY-MM-DD
  def set_scenario_period(scenario_id, ends_on:, set_by_id:)
    ensure_open!
    scenario = @scenarios[live_scenario!(scenario_id)]
    raise TeamPlanning::Error, "The baseline stands on the base date and has no period" unless scenario
    if scenario.relation == "instead"
      raise TeamPlanning::Error, "#{scenario.name} is an alternative: it takes its period from #{name_of(scenario.parent_id)}"
    end

    ends_on = require_date(ends_on)
    return if ends_on == scenario.ends_on

    ensure_periods_fit!(scenario_id => ends_on)
    apply(TeamPlanning::Events::ScenarioPeriodSet.new(data: {
      plan_id: @plan_id, scenario_id: scenario_id, starts_on: period_of(scenario_id).begin.iso8601,
      ends_on: ends_on.iso8601, previous_ends_on: scenario.ends_on.iso8601, set_by_id: set_by_id
    }))
  end

  # Removes a scenario nothing forks from.
  #
  # @param scenario_id [String]
  # @param removed_by_id [String]
  # @raise [TeamPlanning::Error] if the plan is gone, the scenario unknown or
  #   the root, or if scenarios still fork from it
  def remove_scenario(scenario_id, removed_by_id:)
    ensure_open!
    scenario = @scenarios[live_scenario!(scenario_id)]
    raise TeamPlanning::Error, "The baseline can't be removed" unless scenario

    children = children_of(scenario_id).size
    if children.positive?
      raise TeamPlanning::Error,
            "#{children} #{children == 1 ? "scenario forks" : "scenarios fork"} from #{scenario.name}: remove #{children == 1 ? "it" : "them"} first"
    end

    apply(TeamPlanning::Events::ScenarioRemoved.new(data: {
      plan_id: @plan_id, scenario_id: scenario_id, removed_by_id: removed_by_id
    }))
  end

  # Records the end state of one facet of one subject in a scenario.
  #
  # @param kind [Class<TeamPlanning::Events::Change>]
  # @param scenario_id [String] the root or a live scenario
  # @param subject_id [String]
  # @param set_by_id [String] person_id of the actor
  # @param end_state [Hash] the kind's own fields
  # @raise [TeamPlanning::Error] if the plan is deleted, the scenario unknown or the end state refused
  def set_change(kind, scenario_id:, subject_id:, set_by_id:, **end_state)
    raise ArgumentError, "#{kind} is not a kind of change" unless kind < TeamPlanning::Events::Change

    ensure_open!
    live_scenario!(scenario_id)
    apply(kind.new(data: { plan_id: @plan_id, scenario_id:, subject_id:, **kind.end_state(end_state), set_by_id: }))
  end

  # @param scenario_id [String]
  # @return [Array<TeamPlanning::Events::Change>] the scenario's own changes, oldest first
  def changes_in(scenario_id) = @changes.fetch(scenario_id, []).dup

  # The scenarios whose changes a scenario resolves through, root first and
  # the scenario last. An alternative follows its parent, so it starts as the
  # parent plus its own differences.
  #
  # @param scenario_id [String] the root or a live scenario
  # @return [Array<String>]
  # @raise [TeamPlanning::Error] for a scenario the plan doesn't have
  def resolution_chain(scenario_id)
    return [ @plan_id ] if live_scenario!(scenario_id) == @plan_id

    resolution_chain(@scenarios.fetch(scenario_id).parent_id) + [ scenario_id ]
  end

  # The steps from the root to a scenario as the timeline lays them out. An
  # alternative takes its parent's place, so the path has one entry per step.
  #
  # @param scenario_id [String] the root or a live scenario
  # @return [Array<String>]
  # @raise [TeamPlanning::Error] for a scenario the plan doesn't have
  def timeline_path(scenario_id)
    return [ @plan_id ] if live_scenario!(scenario_id) == @plan_id

    scenario = @scenarios.fetch(scenario_id)
    path = timeline_path(scenario.parent_id)
    (scenario.relation == "instead" ? path[0...-1] : path) + [ scenario_id ]
  end

  # @return [Hash{String => Scenario}] the live scenarios, by id, without the root
  def scenarios = @scenarios.dup

  # @param scenario_id [String]
  # @return [Boolean] whether it is the root or a live scenario of this plan
  def scenario?(scenario_id) = scenario_id == @plan_id || @scenarios.key?(scenario_id)

  # The days a scenario covers, from the tree.
  #
  # @param scenario_id [String] a live scenario
  # @param ends [Hash{String => Date}] `then` ends to use in place of those held
  # @return [Range<Date>, nil] nil for the root
  def period_of(scenario_id, ends = {})
    scenario = @scenarios.fetch(scenario_id) { return nil }
    return period_of(scenario.parent_id, ends) if scenario.relation == "instead"

    starts_on = scenario.parent_id == @plan_id ? @base_on : period_of(scenario.parent_id, ends).end + 1
    starts_on..ends.fetch(scenario_id, scenario.ends_on)
  end

  # @return [Hash{String => String}] person_id to role
  def members = @members.dup

  # @param person_id [String, nil]
  # @return [String, nil] "editor", "viewer", or nil for a non-member
  def role_of(person_id) = @members[person_id]

  # @param person_id [String, nil]
  # @return [Boolean]
  def member?(person_id) = @members.key?(person_id)

  # @return [Array<String>] person ids
  def editor_ids = @members.select { |_, role| role == "editor" }.keys

  # @return [Boolean] whether the plan has been created
  def exists? = !@plan_id.nil?

  # @return [Boolean]
  def deleted? = @deleted == true

  on TeamPlanning::Events::PlanCreated do |event|
    @plan_id = event.data[:plan_id]
    @name = event.data[:name]
    @base_on = Date.iso8601(event.data[:base_on])
    @created_by_id = event.data[:created_by_id]
    @members[@created_by_id] = "editor"
  end

  on TeamPlanning::Events::PlanMemberAdded do |event|
    @members[event.data[:person_id]] = event.data[:role]
  end

  on TeamPlanning::Events::PlanMemberRemoved do |event|
    @members.delete(event.data[:person_id])
  end

  on TeamPlanning::Events::PlanRenamed do |event|
    @name = event.data[:name]
  end

  on TeamPlanning::Events::PlanDeleted do |_event|
    @deleted = true
  end

  on TeamPlanning::Events::ScenarioForked do |event|
    data = event.data
    ends_on = Date.iso8601(data[:ends_on]) if data[:relation] == "then"
    @scenarios[data[:scenario_id]] = Scenario.new(id: data[:scenario_id], parent_id: data[:parent_id],
                                                  relation: data[:relation], name: data[:name], ends_on:)
  end

  on TeamPlanning::Events::ScenarioPeriodSet do |event|
    id = event.data[:scenario_id]
    @scenarios[id] = @scenarios.fetch(id).with(ends_on: Date.iso8601(event.data[:ends_on]))
  end

  on TeamPlanning::Events::ScenarioRemoved do |event|
    @scenarios.delete(event.data[:scenario_id])
    @changes.delete(event.data[:scenario_id])
    @removed_scenario_ids << event.data[:scenario_id]
  end

  private

  def record_change(event)
    (@changes[event.data[:scenario_id]] ||= []) << event
  end

  def ensure_editor_remains!(person_id)
    return unless editor_ids == [ person_id ]

    raise TeamPlanning::Error, "A plan needs an editor: make someone else an editor first"
  end

  def ensure_open!
    raise TeamPlanning::Error, "No such plan" unless exists?
    raise TeamPlanning::Error, "#{@name} has been deleted" if deleted?
  end

  def require_date(value)
    return value if value.is_a?(Date)
    raise Date::Error, "invalid date: #{value.inspect}" unless value.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)

    Date.iso8601(value)
  end

  def require_name(name, kind = "plan")
    name = name.to_s.squish
    raise TeamPlanning::Error, "A #{kind} needs a name" if name.empty?
    raise TeamPlanning::Error, "A #{kind}'s name can be at most #{NAME_LIMIT} characters" if name.length > NAME_LIMIT

    name
  end

  def scenario_id_taken?(scenario_id)
    scenario_id == @plan_id || @scenarios.key?(scenario_id) || @removed_scenario_ids.include?(scenario_id)
  end

  # @return [String] the id, once it names the root or a live scenario
  def live_scenario!(scenario_id)
    return scenario_id if scenario?(scenario_id)

    raise TeamPlanning::Error, "This plan has no such scenario"
  end

  def children_of(scenario_id) = @scenarios.values.select { it.parent_id == scenario_id }

  # A `then` starts where the tree says and ends where asked; an `instead`
  # takes its parent's period. A parent has at most one `then`, so a step's
  # alternatives are `instead` scenarios and never a second next step.
  def forked_period(parent_id, relation, starts_on:, ends_on:)
    starts_on = require_date(starts_on) unless starts_on.nil?
    ends_on = require_date(ends_on) unless ends_on.nil?
    relation == "then" ? next_step(parent_id, starts_on, ends_on) : alternative(parent_id, starts_on, ends_on)
  end

  def next_step(parent_id, starts_on, ends_on)
    if (taken = children_of(parent_id).find { it.relation == "then" })
      raise TeamPlanning::Error, "#{taken.name} already follows #{name_of(parent_id)}: fork an alternative to it instead"
    end

    start = parent_id == @plan_id ? @base_on : period_of(parent_id).end + 1
    if starts_on && starts_on != start
      raise TeamPlanning::Error, "A step after #{name_of(parent_id)} starts on #{start.iso8601}, the day it begins"
    end
    raise TeamPlanning::Error, "Say when this step ends" if ends_on.nil?
    raise TeamPlanning::Error, "This step would end on #{ends_on.iso8601}, before it starts on #{start.iso8601}" if ends_on < start

    start..ends_on
  end

  def alternative(parent_id, starts_on, ends_on)
    raise TeamPlanning::Error, "The baseline has no alternative: fork a step after it instead" if parent_id == @plan_id

    period = period_of(parent_id)
    unless [ starts_on || period.begin, ends_on || period.end ] == [ period.begin, period.end ]
      raise TeamPlanning::Error,
            "An alternative covers #{name_of(parent_id)}'s period, #{period.begin.iso8601} to #{period.end.iso8601}"
    end

    period
  end

  # Refuses ends that would leave any live scenario ending before it starts,
  # naming the first in the tree.
  def ensure_periods_fit!(ends)
    @scenarios.each_key do |id|
      period = period_of(id, ends)
      next unless period.end < period.begin

      raise TeamPlanning::Error,
            "#{@scenarios[id].name} would end on #{period.end.iso8601}, before it starts on #{period.begin.iso8601}"
    end
  end

  def name_of(scenario_id) = scenario_id == @plan_id ? "the baseline" : @scenarios.fetch(scenario_id).name
end
