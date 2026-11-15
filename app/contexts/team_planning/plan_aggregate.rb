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
# A member may also hold the see-pay right, which its creator holds from the
# start. The last holder can neither give it up nor leave, so someone can
# always grant it.
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
  include AggregateRoot.with(
    strategy: -> { Shreddable::RedactingApplyStrategy.new(TeamPlanning::ChangeAwareApplyStrategy.new) }
  )

  NAME_LIMIT = 120
  NOTE_LIMIT = 2_000
  DESCRIPTION_LIMIT = 500
  # A description the caller couldn't read, so {#describe_scenario} writes.
  UNKNOWN = Object.new.freeze

  # A browser submits each line break as CRLF but counts it as one character
  # against the field's maxlength, so the limit counts it as one too.
  #
  # @param text [String, nil]
  # @return [String, nil] the description as stored, nil for a blank
  def self.normalise_description(text) = text.to_s.gsub("\r\n", "\n").strip.presence

  ROLES = %w[editor viewer].freeze
  RELATIONS = %w[then instead].freeze
  # A conflict an update carries: where it was read, its key, and the change it read.
  CONFLICT_FIELDS = %i[scenario_id subject_id facet change_id].freeze

  # A scenario as the plan holds it. `ends_on` is held only for a `then`
  # scenario; {#period_of} works out every period. Names are shreddable, so
  # the plan holds none: a replay without keys must decide the same.
  Scenario = Data.define(:id, :parent_id, :relation, :ends_on)

  # @return [String, nil]
  attr_reader :plan_id, :base_on, :created_by_id

  def initialize
    @members = {}
    @pay_holders = Set.new
    @scenarios = {}
    @removed_scenario_ids = Set.new
    @logs = {}
    @undone = Set.new
    @redo_stacks = {}
    @carried = {}
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

  # Renames the plan. The plan holds no name, so the caller says what it is
  # called now; the same name writes nothing.
  #
  # @param name [String]
  # @param current [String, nil] the name it has now
  # @param renamed_by_id [String]
  # @raise [TeamPlanning::Error] if the plan is gone, or the name is blank or too long
  def rename(name, current:, renamed_by_id:)
    ensure_open!
    name = require_name(name)
    return if name == current

    apply(TeamPlanning::Events::PlanRenamed.new(data: {
      plan_id: @plan_id, name: name, previous_name: current, renamed_by_id: renamed_by_id
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

  # Moves the plan's base to a later day. Every scenario re-resolves over the
  # Org Graph on the new base; nothing else is written. A `then` step under
  # the baseline starts on the base, so its start moves too.
  #
  # @param base_on [Date, String] the new base, today when a planner updates
  # @param expected_base_on [Date, String] the base the caller last read, so a
  #   move made since refuses rather than hiding drift they never saw
  # @param conflicts [Array<Hash>] `{ scenario_id, subject_id, facet, change_id }`
  #   for each change reading conflicting now: the scenario it was read in, and
  #   the change that scenario resolved to then
  # @param rebased_by_id [String]
  # @raise [TeamPlanning::Error] if the plan is gone, moved since, already on
  #   that day or later, a first step would end before the new base, or a
  #   conflict names a scenario the plan doesn't have
  # @raise [Date::Error] for a date that isn't YYYY-MM-DD
  def rebase(base_on:, expected_base_on:, conflicts:, rebased_by_id:)
    ensure_open!
    base_on = require_date(base_on)
    if require_date(expected_base_on) != @base_on
      raise TeamPlanning::Error, "This plan has moved since you looked: it now stands on #{@base_on.iso8601}"
    end
    raise TeamPlanning::Error, "This plan already stands on #{@base_on.iso8601}" if base_on == @base_on
    raise TeamPlanning::Error, "This plan stands on #{@base_on.iso8601}, after #{base_on.iso8601}: a base only moves forward" if base_on < @base_on

    ensure_first_steps_reach!(base_on)
    apply(TeamPlanning::Events::PlanRebased.new(data: {
      plan_id: @plan_id, base_on: base_on.iso8601, previous_base_on: @base_on.iso8601,
      conflicts: conflict_keys!(conflicts), rebased_by_id:
    }))
  end

  # The conflicts the last update to today found in a scenario that still
  # stand: the scenario still resolves the key to the change the update saw.
  # A set, pin, clear or undo along its chain ends one, and a redo brings it
  # back.
  #
  # @param scenario_id [String] the scenario the conflict was read in
  # @return [Hash{Array(String, String) => Date}] subject and facet => the base the update that first found it moved to
  def carried_conflicts(scenario_id)
    carried = @carried.fetch(scenario_id, {})
    return {} if carried.empty?

    winning = winning_changes(scenario_id)
    carried.each_with_object({}) do |(key, (change_id, since)), open|
      open[key] = since if winning[key]&.event_id == change_id
    end
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
  # @param departed [Boolean] they have left or been forgotten, so taking them
  #   off can't lock the plan out of pay any further than it already is
  # @raise [TeamPlanning::Error] if the plan is gone, they aren't a member, or
  #   they are its last editor or, unless departed, its last pay holder
  def remove_member(person_id, removed_by_id:, departed: false)
    ensure_open!
    raise TeamPlanning::Error, "They aren't a member of this plan" unless member?(person_id)

    ensure_editor_remains!(person_id)
    ensure_pay_holder_remains!(person_id) unless departed
    apply(TeamPlanning::Events::PlanMemberRemoved.new(data: {
      plan_id: @plan_id, person_id: person_id, removed_by_id: removed_by_id
    }))
  end

  # Lets a member see pay in the plan. A member who holds it already writes
  # nothing.
  #
  # @param person_id [String]
  # @param granted_by_id [String]
  # @param recovery [Boolean] a tenant admin restoring a locked-out plan
  # @raise [TeamPlanning::Error] if the plan is gone or they aren't a member
  def grant_see_pay(person_id, granted_by_id:, recovery: false)
    ensure_open!
    raise TeamPlanning::Error, "They aren't a member of this plan" unless member?(person_id)
    return if sees_pay?(person_id)

    data = { plan_id: @plan_id, person_id: person_id, granted_by_id: granted_by_id }
    data[:recovery] = true if recovery
    apply(TeamPlanning::Events::SeePayGranted.new(data: data))
  end

  # Takes the see-pay right from a member. One who doesn't hold it writes
  # nothing.
  #
  # @param person_id [String]
  # @param withdrawn_by_id [String]
  # @raise [TeamPlanning::Error] if the plan is gone, they aren't a member, or
  #   they are its last holder
  def withdraw_see_pay(person_id, withdrawn_by_id:)
    ensure_open!
    raise TeamPlanning::Error, "They aren't a member of this plan" unless member?(person_id)
    return unless sees_pay?(person_id)

    ensure_pay_holder_remains!(person_id)
    apply(TeamPlanning::Events::SeePayWithdrawn.new(data: {
      plan_id: @plan_id, person_id: person_id, withdrawn_by_id: withdrawn_by_id
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

  # Renames a scenario. The same name writes nothing.
  #
  # @param scenario_id [String]
  # @param name [String]
  # @param current [String, nil] the name it has now: the plan holds no name, so the caller says
  # @param renamed_by_id [String]
  # @raise [TeamPlanning::Error] if the plan is gone, the scenario unknown or
  #   the baseline, or the name is blank or too long
  def rename_scenario(scenario_id, name:, current:, renamed_by_id:)
    ensure_open!
    raise TeamPlanning::Error, "The baseline can't be renamed" unless @scenarios[live_scenario!(scenario_id)]

    name = require_name(name, "scenario")
    return if name == current

    apply(TeamPlanning::Events::ScenarioRenamed.new(data: {
      plan_id: @plan_id, scenario_id: scenario_id, name: name, previous_name: current, renamed_by_id: renamed_by_id
    }))
  end

  # Says what a scenario is for, or clears it with a blank. The aggregate
  # never sees a description once written, so the caller says what the
  # scenario holds now, read from a projection, and the same text writes
  # nothing. {UNKNOWN}, when the caller can't be sure, always writes.
  #
  # @param scenario_id [String]
  # @param description [String, nil]
  # @param described_by_id [String]
  # @param current [#call] gives the description now, or {UNKNOWN}; called
  #   only once the command passes its checks
  # @raise [TeamPlanning::Error] if the plan is gone, the scenario unknown or
  #   the baseline, or the description too long
  def describe_scenario(scenario_id, description:, described_by_id:, current: -> { UNKNOWN })
    ensure_open!
    raise TeamPlanning::Error, "The baseline can't be described" unless @scenarios[live_scenario!(scenario_id)]

    description = self.class.normalise_description(description)
    if description && description.length > DESCRIPTION_LIMIT
      raise TeamPlanning::Error, "A scenario's description can be at most #{DESCRIPTION_LIMIT} characters"
    end
    return if description == current.call

    apply(TeamPlanning::Events::ScenarioDescribed.new(data: {
      plan_id: @plan_id, scenario_id: scenario_id, description: description, described_by_id: described_by_id
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
      raise TeamPlanning::Error, "This scenario is an alternative: it takes its period from #{parent_of(scenario.parent_id)}"
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
            "#{children} #{children == 1 ? "scenario forks" : "scenarios fork"} from this one: remove #{children == 1 ? "it" : "them"} first"
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
  # @param end_state [Hash] the kind's own fields, none of them a field every change holds
  # @param note [String, nil] why, kept apart from the end state; blank for none
  # @yieldparam plan [TeamPlanning::PlanAggregate] once the plan is open and the scenario known, for the
  #   caller's own checks, such as one against a projection, which this aggregate never reads
  # @raise [TeamPlanning::Error] if the plan is deleted, the scenario unknown, the end state refused or the note too long
  # @raise [ArgumentError] for a kind that is not a change, or an end state naming a field every change holds
  def set_change(kind, scenario_id:, subject_id:, set_by_id:, end_state: {}, note: nil)
    raise ArgumentError, "#{kind} is not a kind of change" unless kind.is_a?(Class) && kind < TeamPlanning::Events::Change
    raise ArgumentError, "#{kind} must name its facet and say how it lands on a map" unless kind.complete?

    ensure_open!
    live_scenario!(scenario_id)
    note = require_note(note)
    yield self if block_given?
    fields = kind.end_state(own_fields!(end_state.to_h.symbolize_keys))
    apply(kind.new(data: with_note({ plan_id: @plan_id, scenario_id:, subject_id:, **own_fields!(fields), set_by_id: }, note)))
  end

  # Every change, pin and clear a scenario made, in order. A pin is the change
  # it stands for, under the pin's event id.
  #
  # @param scenario_id [String]
  # @return [Array<TeamPlanning::Events::Change, TeamPlanning::Events::ChangeCleared>]
  def log_of(scenario_id) = @logs.fetch(scenario_id, []).dup

  # @param scenario_id [String]
  # @return [Array<TeamPlanning::Events::Change>] the scenario's changes in effect, oldest first: its log without what it cleared or undid
  def changes_in(scenario_id) = in_effect(scenario_id, @undone)

  # @param event_id [String] an entry of a scenario's log
  # @return [Boolean] whether that entry stands undone
  def undone?(event_id) = @undone.include?(event_id)

  # Takes back one entry of a scenario's log: a change, a pin or a clear. The
  # scenario then resolves as if it had not been made.
  #
  # @param scenario_id [String] the root or a live scenario
  # @param event_id [String] the entry's event id
  # @param undone_by_id [String] person_id of the actor
  # @raise [TeamPlanning::Error] if the plan is deleted, the scenario unknown,
  #   the entry not in its log or already undone, or a later entry in effect
  #   changes the same subject and facet
  def undo_change(scenario_id:, event_id:, undone_by_id:)
    ensure_open!
    entry = log_entry!(live_scenario!(scenario_id), event_id)
    raise TeamPlanning::Error, "That change is already undone" if undone?(event_id)

    ensure_nothing_later!(scenario_id, entry, "undo")
    subject_id, facet = key_of(entry)
    in_effect_event_id = in_effect_at(scenario_id, [ subject_id, facet ], @undone | [ event_id ])
    apply(TeamPlanning::Events::ChangeUndone.new(data: { plan_id: @plan_id, scenario_id:, subject_id:, facet:, undone_event_id: event_id, undone_by_id:, in_effect_event_id: }))
  end

  # Restores an undone entry of a scenario's log, in its place.
  #
  # @param scenario_id [String] the root or a live scenario
  # @param event_id [String] the entry's event id
  # @param redone_by_id [String] person_id of the actor
  # @raise [TeamPlanning::Error] if the plan is deleted, the scenario unknown,
  #   the entry not in its log or not undone, or a later entry in effect
  #   changes the same subject and facet
  def redo_change(scenario_id:, event_id:, redone_by_id:)
    ensure_open!
    entry = log_entry!(live_scenario!(scenario_id), event_id)
    raise TeamPlanning::Error, "That change isn't undone, so there is nothing to redo" unless undone?(event_id)

    ensure_nothing_later!(scenario_id, entry, "redo")
    subject_id, facet = key_of(entry)
    in_effect_event_id = in_effect_at(scenario_id, [ subject_id, facet ], @undone - [ event_id ])
    apply(TeamPlanning::Events::ChangeRedone.new(data: { plan_id: @plan_id, scenario_id:, subject_id:, facet:, redone_event_id: event_id, redone_by_id:, in_effect_event_id: }))
  end

  # @param scenario_id [String] the root or a live scenario
  # @param event_id [String] an entry of its log
  # @return [String] the facet the entry changes, pins or clears
  # @raise [TeamPlanning::Error] if the scenario is unknown or the entry not in its log
  def facet_of(scenario_id, event_id) = key_of(log_entry!(live_scenario!(scenario_id), event_id)).last

  # Writes, rewrites or clears the note on a change or pin, which must still
  # stand in its scenario: not undone, not cleared and not replaced.
  #
  # @param scenario_id [String] the root or a live scenario
  # @param event_id [String] the change's or pin's event id
  # @param note [String, nil] blank clears it
  # @param noted_by_id [String] person_id of the actor
  # @raise [TeamPlanning::Error] if the plan is deleted, the scenario unknown, the change not in its log or no
  #   longer standing, or the note too long
  def note_change(scenario_id:, event_id:, note:, noted_by_id:)
    ensure_open!
    entry = log_entry!(live_scenario!(scenario_id), event_id)
    raise TeamPlanning::Error, "That change is undone: redo it to note it" if undone?(event_id)

    subject_id, facet = key_of(entry)
    unless changes_in(scenario_id).reverse_each.find { it.key == [ subject_id, facet ] }&.event_id == event_id
      raise TeamPlanning::Error, "That change no longer stands in #{this(scenario_id).downcase}, so it takes no note"
    end

    apply(TeamPlanning::Events::ChangeNoted.new(data: { plan_id: @plan_id, scenario_id:, subject_id:, facet:, noted_event_id: event_id,
                                                        note: require_note(note), noted_by_id: }))
  end

  # What an Undo button takes back for one person: their latest entry in the
  # scenario that is in effect and that nothing later replaced.
  #
  # @param scenario_id [String] the root or a live scenario
  # @param person_id [String]
  # @param except_facets [Array<String>] facets the person may no longer touch
  # @return [String, nil] its event id
  def last_undoable_by(scenario_id, person_id, except_facets: [])
    ensure_open!
    replaced = Set.new
    @logs.fetch(live_scenario!(scenario_id), []).reverse_each do |entry|
      next if undone?(entry.event_id) || except_facets.include?(key_of(entry).last)
      return entry.event_id if actor_of(entry) == person_id && !replaced.include?(key_of(entry))

      replaced << key_of(entry)
    end
    nil
  end

  # What a Redo button restores for one person: the change of their latest
  # undo in the scenario that still stands and can be redone. A change they
  # make after undoing ends what they can redo, as in an editor.
  #
  # @param scenario_id [String] the root or a live scenario
  # @param person_id [String]
  # @param except_facets [Array<String>] facets the person may no longer touch
  # @return [String, nil] the undone entry's event id
  def last_redoable_by(scenario_id, person_id, except_facets: [])
    ensure_open!
    log = @logs.fetch(live_scenario!(scenario_id), [])
    redo_stack(scenario_id, person_id).reverse.find do |event_id|
      entry = log.find { it.event_id == event_id }
      undone?(event_id) && entry && !except_facets.include?(key_of(entry).last) && later_in_effect(log, entry).nil?
    end
  end

  # Stops a scenario overriding one facet of one subject, so it follows its
  # parent there again. The changes it made stay in the stream.
  #
  # @param scenario_id [String] the root or a live scenario
  # @param subject_id [String]
  # @param facet [String] the second half of the change's key
  # @param cleared_by_id [String] person_id of the actor
  # @raise [TeamPlanning::Error] if the plan is deleted, the scenario unknown, or it doesn't change that facet
  def clear_change(scenario_id:, subject_id:, facet:, cleared_by_id:)
    ensure_open!
    ensure_overrides!(live_scenario!(scenario_id), [ subject_id, facet ])

    apply(TeamPlanning::Events::ChangeCleared.new(data: { plan_id: @plan_id, scenario_id:, subject_id:, facet:, cleared_by_id: }))
  end

  # The change a scenario inherits for a key: the last one along its parent's
  # resolution chain.
  #
  # @param scenario_id [String] a live scenario
  # @param key [Array(String, String)] a subject and a facet
  # @return [Array(String, TeamPlanning::Events::Change), nil] the scenario that made it and the change; nil when it comes from the baseline
  def inherited_change(scenario_id, key)
    parent_id = @scenarios.fetch(live_scenario!(scenario_id)) { return nil }.parent_id
    resolution_chain(parent_id).reverse_each do |id|
      change = changes_in(id).reverse_each.find { it.key == key }
      return [ id, change ] if change
    end
    nil
  end

  # Takes the end state a scenario inherits for one facet of one subject as its
  # own change, so a later change in its parent doesn't reach it.
  #
  # @param kind [Class<TeamPlanning::Events::Change>]
  # @param scenario_id [String] a live scenario
  # @param subject_id [String]
  # @param facet [String] the second half of the change's key
  # @param end_state [Hash] what the scenario inherits, as the kind stores it
  # @param pinned_by_id [String] person_id of the actor
  # @param pinned_from [Array(String, String), nil] the scenario and event id of the change it keeps; nil for the baseline
  # @param note [String, nil] why the scenario keeps it; blank for none
  # @raise [TeamPlanning::Error] if the plan is deleted, the scenario unknown or the root, it already changes that facet,
  #   or the note is too long
  # @raise [ArgumentError] for a kind that is not a change, or an end state that doesn't make that key
  def pin_change(kind, scenario_id:, subject_id:, facet:, end_state:, pinned_by_id:, pinned_from: nil, note: nil)
    raise ArgumentError, "#{kind} is not a kind of change" unless kind.is_a?(Class) && kind < TeamPlanning::Events::Change && kind.complete?

    ensure_pinnable!(scenario_id, [ subject_id, facet ])
    note = require_note(note)
    end_state = own_fields!(end_state.to_h.symbolize_keys)
    pinned = pinned_change(kind, { plan_id: @plan_id, scenario_id:, subject_id:, set_by_id: pinned_by_id }, end_state)
    raise ArgumentError, "That end state doesn't make a #{facet} change" unless pinned.key == [ subject_id, facet ]

    from_scenario_id, from_event_id = pinned_from
    apply(TeamPlanning::Events::ChangePinned.new(data: with_note({
      plan_id: @plan_id, scenario_id:, subject_id:, facet:, kind: kind.name, end_state: end_state.to_h,
      pinned_from_scenario_id: from_scenario_id, pinned_from_event_id: from_event_id, pinned_by_id:
    }, note)))
  end

  # Refuses a pin before anyone works out what it would keep.
  #
  # @param scenario_id [String]
  # @param key [Array(String, String)] a subject and a facet
  # @raise [TeamPlanning::Error] if the plan is deleted, the scenario unknown or the root, or it already changes that facet
  def ensure_pinnable!(scenario_id, key)
    ensure_open!
    raise TeamPlanning::Error, "The baseline inherits nothing to pin" if live_scenario!(scenario_id) == @plan_id
    return unless own_change?(scenario_id, key)

    raise TeamPlanning::Error, "#{this(scenario_id)} already changes this: clear it to follow its parent, or set it"
  end

  # The change that wins for each subject and facet along the scenario's
  # resolution chain: the last one made, nearest the scenario.
  #
  # @param scenario_id [String] the root or a live scenario
  # @return [Hash{Array(String, String) => TeamPlanning::Events::Change}] by {TeamPlanning::Events::Change#key}, in the order they land
  # @raise [TeamPlanning::Error] for a scenario the plan doesn't have
  def winning_changes(scenario_id)
    resolution_chain(scenario_id).flat_map { changes_in(it) }
      .each_with_object({}) { |change, latest| latest.delete(change.key); latest[change.key] = change }
  end

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

  # @param person_id [String]
  # @return [Boolean] whether they hold the see-pay right
  def sees_pay?(person_id) = @pay_holders.include?(person_id)

  # @return [Array<String>] the members who hold the see-pay right
  def pay_holder_ids = @pay_holders.to_a

  # @return [Boolean] whether the plan has been created
  def exists? = !@plan_id.nil?

  # @return [Boolean]
  def deleted? = @deleted == true

  on TeamPlanning::Events::PlanCreated do |event|
    @plan_id = event.data[:plan_id]
    @base_on = Date.iso8601(event.data[:base_on])
    @created_by_id = event.data[:created_by_id]
    @members[@created_by_id] = "editor"
    @pay_holders << @created_by_id
  end

  on TeamPlanning::Events::PlanRebased do |event|
    base_on = Date.iso8601(event.data[:base_on])
    conflicts = event.data[:conflicts].map { it.to_h.symbolize_keys }
    @carried = conflicts.group_by { it[:scenario_id] }.to_h do |scenario_id, found|
      earlier = carried_conflicts(scenario_id)
      carried = found.to_h do |conflict|
        key = conflict.values_at(:subject_id, :facet)
        [ key, [ conflict[:change_id], earlier.fetch(key, base_on) ] ]
      end
      [ scenario_id, carried ]
    end
    @base_on = base_on
  end

  on TeamPlanning::Events::PlanMemberAdded do |event|
    @members[event.data[:person_id]] = event.data[:role]
  end

  on TeamPlanning::Events::PlanMemberRemoved do |event|
    @members.delete(event.data[:person_id])
    @pay_holders.delete(event.data[:person_id])
  end

  on TeamPlanning::Events::SeePayGranted do |event|
    @pay_holders << event.data[:person_id]
  end

  on TeamPlanning::Events::SeePayWithdrawn do |event|
    @pay_holders.delete(event.data[:person_id])
  end

  # The plan holds no name.
  on TeamPlanning::Events::PlanRenamed do |_event|
  end

  on TeamPlanning::Events::PlanDeleted do |_event|
    @deleted = true
  end

  on TeamPlanning::Events::ScenarioForked do |event|
    data = event.data
    ends_on = Date.iso8601(data[:ends_on]) if data[:relation] == "then"
    @scenarios[data[:scenario_id]] = Scenario.new(id: data[:scenario_id], parent_id: data[:parent_id],
                                                  relation: data[:relation], ends_on:)
  end

  on TeamPlanning::Events::ScenarioRenamed do |_event|
  end

  on TeamPlanning::Events::ScenarioDescribed do |_event|
  end

  on TeamPlanning::Events::ScenarioPeriodSet do |event|
    id = event.data[:scenario_id]
    @scenarios[id] = @scenarios.fetch(id).with(ends_on: Date.iso8601(event.data[:ends_on]))
  end

  on TeamPlanning::Events::ChangeCleared do |event|
    record_change(event)
  end

  on TeamPlanning::Events::ChangePinned do |event|
    data = event.data
    record_change(pinned_change(data[:kind].constantize, { plan_id: data[:plan_id], scenario_id: data[:scenario_id],
                                                           subject_id: data[:subject_id], set_by_id: data[:pinned_by_id] },
                                data[:end_state], event_id: event.event_id))
  end

  on TeamPlanning::Events::ChangeUndone do |event|
    @undone << event.data[:undone_event_id]
    redo_stack(event.data[:scenario_id], event.data[:undone_by_id]) << event.data[:undone_event_id]
  end

  on TeamPlanning::Events::ChangeRedone do |event|
    @undone.delete(event.data[:redone_event_id])
    @redo_stacks.fetch(event.data[:scenario_id], {}).each_value { it.delete(event.data[:redone_event_id]) }
  end

  on TeamPlanning::Events::ChangeNoted do |_event|
  end

  on TeamPlanning::Events::ScenarioRemoved do |event|
    @scenarios.delete(event.data[:scenario_id])
    @logs.delete(event.data[:scenario_id])
    @redo_stacks.delete(event.data[:scenario_id])
    @carried.delete(event.data[:scenario_id])
    @removed_scenario_ids << event.data[:scenario_id]
  end

  private

  def in_effect(scenario_id, undone)
    @logs.fetch(scenario_id, []).reject { undone.include?(it.event_id) }.each_with_object([]) do |entry, in_effect|
      if entry.is_a?(TeamPlanning::Events::ChangeCleared)
        key = entry.data.values_at(:subject_id, :facet)
        in_effect.reject! { it.key == key }
      else
        in_effect << entry
      end
    end
  end

  # What an undo or redo leaves in effect for one key, so the overrides
  # projection can write it without replaying the stream.
  def in_effect_at(scenario_id, key, undone) = in_effect(scenario_id, undone).reverse_each.find { it.key == key }&.event_id

  # Checked on the caller's fields and on the kind's, so a kind that filters
  # its input can't let a caller's plan_id through unrefused.
  def own_fields!(fields)
    taken = fields.keys & TeamPlanning::Events::Change::FIELDS
    raise ArgumentError, "An end state can't set #{taken.join(", ")}" if taken.any?

    fields
  end

  def own_change?(scenario_id, key) = changes_in(scenario_id).any? { it.key == key }

  def ensure_overrides!(scenario_id, key)
    raise TeamPlanning::Error, "#{this(scenario_id)} doesn't change this, so there is nothing to clear" unless own_change?(scenario_id, key)
  end

  # A pin resolves as a change of the kind it keeps.
  def pinned_change(kind, fields, end_state, event_id: SecureRandom.uuid)
    kind.new(event_id:, data: { **fields, **end_state.to_h.symbolize_keys })
  end

  def log_entry!(scenario_id, event_id)
    @logs.fetch(scenario_id, []).find { it.event_id == event_id } or
      raise TeamPlanning::Error, "#{this(scenario_id)} has no such change"
  end

  def key_of(entry)
    entry.is_a?(TeamPlanning::Events::ChangeCleared) ? entry.data.values_at(:subject_id, :facet) : entry.key
  end

  def actor_of(entry) = entry.data[:set_by_id] || entry.data[:cleared_by_id]

  def later_in_effect(log, entry)
    log.drop(log.index(entry) + 1).reverse_each.find { !undone?(it.event_id) && key_of(it) == key_of(entry) }
  end

  # Taking back or restoring an entry under a later one would change nothing
  # anyone can see, or bring back a value two steps old.
  def ensure_nothing_later!(scenario_id, entry, action)
    later = later_in_effect(@logs.fetch(scenario_id), entry) or return

    raise TeamPlanning::Error, "A later change to this replaced it (#{later.event_id}): undo that first, then #{action} this"
  end

  def record_change(event)
    (@logs[event.data[:scenario_id]] ||= []) << event
    redo_stack(event.data[:scenario_id], actor_of(event)).clear
  end

  def redo_stack(scenario_id, person_id) = (@redo_stacks[scenario_id] ||= {})[person_id] ||= []

  def ensure_editor_remains!(person_id)
    return unless editor_ids == [ person_id ]

    raise TeamPlanning::Error, "A plan needs an editor: make someone else an editor first"
  end

  def ensure_pay_holder_remains!(person_id)
    return unless pay_holder_ids == [ person_id ]

    raise TeamPlanning::Error, "A plan needs someone who can see pay: give the right to someone else first"
  end

  def ensure_open!
    raise TeamPlanning::Error, "No such plan" unless exists?
    raise TeamPlanning::Error, "This plan has been deleted" if deleted?
  end

  def require_date(value)
    return value if value.is_a?(Date)
    raise Date::Error, "invalid date: #{value.inspect}" unless value.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)

    Date.iso8601(value)
  end

  # A change without a note holds no note field, so it is stored as it was before notes.
  def with_note(data, note) = note ? data.merge(note:) : data

  def require_note(note)
    note = note.to_s.strip.presence or return nil
    raise TeamPlanning::Error, "A note can be at most #{NOTE_LIMIT} characters" if note.length > NOTE_LIMIT

    note
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
    if children_of(parent_id).any? { it.relation == "then" }
      raise TeamPlanning::Error, "#{parent_of(parent_id).upcase_first} already has a next step: fork an alternative to that step instead"
    end

    start = parent_id == @plan_id ? @base_on : period_of(parent_id).end + 1
    if starts_on && starts_on != start
      raise TeamPlanning::Error, "A step after #{parent_of(parent_id)} starts on #{start.iso8601}, the day it begins"
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
            "An alternative covers #{parent_of(parent_id)}'s period, #{period.begin.iso8601} to #{period.end.iso8601}"
    end

    period
  end

  def ensure_first_steps_reach!(base_on)
    step = children_of(@plan_id).find { it.relation == "then" && it.ends_on < base_on } or return

    raise TeamPlanning::FirstStepEndsTooSoon.new(scenario_id: step.id, ends_on: step.ends_on, base_on:)
  end

  def conflict_keys!(conflicts)
    conflicts.map { it.to_h.symbolize_keys.slice(*CONFLICT_FIELDS) }.uniq.each do |conflict|
      unless conflict.size == CONFLICT_FIELDS.size && conflict.values.all?(String)
        raise TeamPlanning::Error, "A conflict needs a scenario_id, subject_id, facet and change_id"
      end

      live_scenario!(conflict[:scenario_id])
    end
  end

  # Refuses ends that would leave any live scenario ending before it starts,
  # naming the first in the tree.
  def ensure_periods_fit!(ends)
    @scenarios.each_key do |id|
      period = period_of(id, ends)
      next unless period.end < period.begin

      raise TeamPlanning::Error,
            "#{ends.key?(id) ? "This scenario" : "A scenario after it"} would end on #{period.end.iso8601}, before it starts on #{period.begin.iso8601}"
    end
  end

  def parent_of(scenario_id) = scenario_id == @plan_id ? "the baseline" : "its parent"

  def this(scenario_id) = scenario_id == @plan_id ? "The baseline" : "This scenario"
end
