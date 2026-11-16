# frozen_string_literal: true

# Handles commands for plan aggregates.
#
# Each method loads the plan's stream under its lock, checks {PlanPolicy}
# against the plan as its stream has it, runs the command and stores the
# events. Every handler names its actor, and the actor must be a person: a
# plan's changes carry who made them.
#
class TeamPlanning::CommandHandler
  # @param actor [AuthorizationContext] who is acting
  # @param repository [TeamPlanning::Repository]
  # @raise [ArgumentError] without an actor
  def initialize(actor:, repository: TeamPlanning::Repository.new)
    unless actor.is_a?(AuthorizationContext)
      raise ArgumentError, "A Team Planning handler needs an actor: an AuthorizationContext"
    end

    @actor = actor
    @repository = repository
  end

  # @param plan_id [String] UUID minted by the caller
  # @param name [String]
  # @param base_on [Date, String]
  # @param unit_ids [Array<String>] the units it covers, none for the whole organisation
  # @return [TeamPlanning::PlanAggregate] the plan as stored
  # @raise [Pundit::NotAuthorizedError] unless the actor may create a plan
  # @raise [TeamPlanning::Error] for a unit the Org Graph hasn't
  # @see TeamPlanning::PlanAggregate#create
  def create_plan(plan_id, name:, base_on:, unit_ids: [])
    created_by_id = actor_id!
    authorize!(:create?, nil) { "Only a tenant admin or a planner can create a plan" }
    unit_ids = known_units!(unit_ids)
    @repository.with_plan(plan_id) do |plan|
      plan.create(plan_id, name: name, base_on: base_on, created_by_id: created_by_id)
      plan.set_scope(unit_ids:, set_by_id: created_by_id)
    end
  end

  # Sets the units a plan covers. Narrowing is checked by the caller, which
  # reads the plan's changes; this checks the units exist.
  #
  # @param plan_id [String]
  # @param unit_ids [Array<String>] empty for the whole organisation
  # @return [TeamPlanning::PlanAggregate] the plan as stored
  # @raise [TeamPlanning::Error] "No such plan" unless the actor is an editor, or for a unit the Org Graph hasn't
  # @see TeamPlanning::PlanAggregate#set_scope
  def set_plan_scope(plan_id, unit_ids:)
    @repository.with_plan(plan_id) do |plan|
      authorize_plan!(:update?, plan)
      unit_ids = known_units!(unit_ids, kept: plan.scope_unit_ids.to_a)
      yield plan, unit_ids if block_given?
      plan.set_scope(unit_ids:, set_by_id: actor_id!)
    end
  end

  # @param plan_id [String]
  # @param name [String]
  # @return [TeamPlanning::PlanAggregate] the plan as stored
  # @raise [TeamPlanning::Error] "No such plan" unless the actor is an editor
  # @see TeamPlanning::PlanAggregate#rename
  def rename_plan(plan_id, name)
    @repository.with_plan(plan_id) do |plan|
      authorize_plan!(:update?, plan)
      plan.rename(name, current: TeamPlanningPlan.find_by(id: plan_id)&.name&.reveal, renamed_by_id: actor_id!)
    end
  end

  # @param plan_id [String]
  # @return [TeamPlanning::PlanAggregate] the plan as stored
  # @raise [TeamPlanning::Error] "No such plan" unless the actor is an editor
  # @see TeamPlanning::PlanAggregate#delete
  def delete_plan(plan_id)
    @repository.with_plan(plan_id) do |plan|
      authorize_plan!(:destroy?, plan)
      plan.delete(deleted_by_id: actor_id!)
    end
  end

  # Deletes a frozen plan, one no editor can reach any more, for a tenant
  # admin who never opens it.
  #
  # @param plan_id [String]
  # @param reason [String] why, kept on the event
  # @return [TeamPlanning::PlanAggregate] the plan as stored
  # @raise [TeamPlanning::Error] "No such plan" unless the plan is frozen and
  #   the actor a tenant admin; or if the reason is blank
  def delete_frozen_plan(plan_id, reason:)
    reason = reason.to_s.squish
    raise TeamPlanning::Error, "Say why you are deleting this plan" if reason.empty?

    @repository.with_plan(plan_id) do |plan|
      authorize_plan!(:destroy_frozen?, plan)
      plan.delete(deleted_by_id: actor_id!, reason: reason)
    end
  end

  # @param plan_id [String]
  # @return [TeamPlanning::PlanAggregate] the plan as stored
  # @raise [TeamPlanning::Error] "No such plan" unless the actor is an editor; or if it is already archived
  # @see TeamPlanning::PlanAggregate#archive
  def archive_plan(plan_id)
    @repository.with_plan(plan_id) do |plan|
      authorize_plan!(:update?, plan)
      plan.archive(archived_by_id: actor_id!, prices: method(:frozen_prices))
    end
  end

  # @param plan_id [String]
  # @return [TeamPlanning::PlanAggregate] the plan as stored
  # @raise [TeamPlanning::Error] "No such plan" unless the actor is an editor; or if it isn't archived
  # @see TeamPlanning::PlanAggregate#restore
  def restore_plan(plan_id)
    @repository.with_plan(plan_id) do |plan|
      authorize_plan!(:update?, plan)
      plan.restore(restored_by_id: actor_id!)
    end
  end

  # Makes someone a member of the plan, or changes their role.
  #
  # @param plan_id [String]
  # @param person_id [String] an active, unforgotten person in the tenant
  # @param role [String] "editor" or "viewer"
  # @return [TeamPlanning::PlanAggregate] the plan as stored
  # @raise [TeamPlanning::Error] "No such plan" unless the actor is an editor;
  #   or if the person can't join, or the plan would lose its last editor
  # @see TeamPlanning::PlanAggregate#add_member
  def add_member(plan_id, person_id, role:)
    @repository.with_plan(plan_id) do |plan|
      authorize_plan!(:manage_members?, plan)
      ensure_can_join!(plan, person_id, role)

      ensure_reachable_editor_remains!(plan, person_id) if role.to_s == "viewer"
      plan.add_member(person_id, role: role, added_by_id: actor_id!)
    end
  end

  # Takes a member off the plan. An editor may remove anyone; any member may
  # remove themselves.
  #
  # @param plan_id [String]
  # @param person_id [String]
  # @return [TeamPlanning::PlanAggregate] the plan as stored
  # @raise [TeamPlanning::Error] "No such plan" unless the actor may; or if
  #   the plan would lose its last editor
  # @see TeamPlanning::PlanAggregate#remove_member
  def remove_member(plan_id, person_id)
    @repository.with_plan(plan_id) do |plan|
      authorize_plan!(person_id == @actor.person&.id ? :leave? : :manage_members?, plan)
      ensure_reachable_editor_remains!(plan, person_id)
      departed = PlanPolicy.reachable_ids([ person_id ]).empty?
      ensure_reachable_holder_remains!(plan, person_id) unless departed
      plan.remove_member(person_id, removed_by_id: actor_id!, departed:)
    end
  end

  # Gives a member the see-pay right. Only a member who holds it may.
  #
  # @param plan_id [String]
  # @param person_id [String] a member still active in the tenant
  # @return [TeamPlanning::PlanAggregate] the plan as stored
  # @raise [TeamPlanning::Error] "No such plan" unless the actor holds the
  #   right; or if the person isn't a member who can still open the plan
  # @see TeamPlanning::PlanAggregate#grant_see_pay
  def grant_see_pay(plan_id, person_id)
    @repository.with_plan(plan_id) do |plan|
      authorize_plan!(:manage_see_pay?, plan)
      if plan.member?(person_id) && PlanPolicy.reachable_ids([ person_id ]).empty?
        raise TeamPlanning::Error, "Only a member still active in this organisation can be given the right"
      end

      plan.grant_see_pay(person_id, granted_by_id: actor_id!)
    end
  end

  # Takes the see-pay right from a member, or lets a holder give it up.
  #
  # @param plan_id [String]
  # @param person_id [String]
  # @return [TeamPlanning::PlanAggregate] the plan as stored
  # @raise [TeamPlanning::Error] "No such plan" unless the actor holds the
  #   right; or if nobody else who can still open the plan would hold it
  # @see TeamPlanning::PlanAggregate#withdraw_see_pay
  def withdraw_see_pay(plan_id, person_id)
    @repository.with_plan(plan_id) do |plan|
      authorize_plan!(:manage_see_pay?, plan)
      ensure_reachable_holder_remains!(plan, person_id)
      plan.withdraw_see_pay(person_id, withdrawn_by_id: actor_id!)
    end
  end

  # Gives the see-pay right to every editor who can still open a plan locked
  # out of pay, for a tenant admin who never opens it. Each grant names the
  # admin and is marked as a recovery.
  #
  # @param plan_id [String]
  # @return [TeamPlanning::PlanAggregate] the plan as stored
  # @raise [TeamPlanning::Error] "No such plan" for a plan that isn't locked
  #   out, one with no editor left, a deleted or missing one, and a caller who
  #   isn't a tenant admin alike, so it reveals nothing about the plan
  def restore_see_pay(plan_id)
    @repository.with_plan(plan_id) do |plan|
      raise TeamPlanning::Error, "No such plan" if plan.deleted?

      authorize_plan!(:restore_see_pay?, plan)

      admin_id = actor_id!
      PlanPolicy.reachable_ids(plan.editor_ids).sort.each do |editor_id|
        plan.grant_see_pay(editor_id, granted_by_id: admin_id, recovery: true)
      end
    end
  end

  # @param plan_id [String]
  # @param scenario_id [String] UUID minted by the caller
  # @param parent_id [String] a scenario in the plan, or the plan's id for the baseline
  # @param relation [String] "then" or "instead"
  # @param name [String]
  # @param ends_on [Date, String, nil]
  # @param starts_on [Date, String, nil]
  # @return [TeamPlanning::PlanAggregate] the plan as stored
  # @raise [TeamPlanning::Error] "No such plan" unless the actor is an editor
  # @see TeamPlanning::PlanAggregate#fork_scenario
  def fork_scenario(plan_id, scenario_id, parent_id:, relation:, name:, ends_on: nil, starts_on: nil)
    @repository.with_plan(plan_id) do |plan|
      authorize_plan!(:update?, plan)
      plan.fork_scenario(scenario_id, parent_id:, relation:, name:, ends_on:, starts_on:, forked_by_id: actor_id!)
    end
  end

  # Moves the named changes into an agreed part beneath the scenario. What a
  # moving change may need is read from the parent's resolved map.
  #
  # @param plan_id [String]
  # @param scenario_id [String]
  # @param agreed_id [String] UUID minted by the caller
  # @param name [String] the agreed part's
  # @param event_ids [Array<String>] changes or pins in effect in the scenario
  # @return [TeamPlanning::PlanAggregate] the plan as stored
  # @raise [TeamPlanning::SplitBlocked] if a moving change needs what a staying one creates
  # @raise [TeamPlanning::Error] "No such plan" unless the actor is an editor
  # @see TeamPlanning::PlanAggregate#split_scenario
  def split_scenario(plan_id, scenario_id, agreed_id:, name:, event_ids:)
    @repository.with_plan(plan_id) do |plan|
      authorize_plan!(:update?, plan)
      plan.split_scenario(scenario_id, agreed_id:, name:, event_ids:, standing_ids: standing_ids(plan, scenario_id),
                                       split_by_id: actor_id!)
    end
  end

  # @param plan_id [String]
  # @param scenario_id [String]
  # @param name [String]
  # @return [TeamPlanning::PlanAggregate] the plan as stored
  # @raise [TeamPlanning::Error] "No such plan" unless the actor is an editor
  # @see TeamPlanning::PlanAggregate#rename_scenario
  def rename_scenario(plan_id, scenario_id, name:)
    @repository.with_plan(plan_id) do |plan|
      authorize_plan!(:update?, plan)
      current = TeamPlanningScenario.find_by(id: scenario_id, plan_id:)&.name&.reveal
      plan.rename_scenario(scenario_id, name:, current:, renamed_by_id: actor_id!)
    end
  end

  # @param plan_id [String]
  # @param scenario_id [String]
  # @param description [String, nil]
  # @param current [#call] gives the description the scenario holds now, or
  #   {TeamPlanning::PlanAggregate::UNKNOWN}; called under the plan's lock,
  #   once the actor is allowed and the command valid
  # @return [TeamPlanning::PlanAggregate] the plan as stored
  # @raise [TeamPlanning::Error] "No such plan" unless the actor is an editor
  # @see TeamPlanning::PlanAggregate#describe_scenario
  def describe_scenario(plan_id, scenario_id, description:, current: -> { TeamPlanning::PlanAggregate::UNKNOWN })
    @repository.with_plan(plan_id) do |plan|
      authorize_plan!(:update?, plan)
      plan.describe_scenario(scenario_id, description:, described_by_id: actor_id!, current:)
    end
  end

  # @param plan_id [String]
  # @param scenario_id [String]
  # @param ends_on [Date, String]
  # @param starts_on [Date, String, nil] a first step's new start
  # @return [TeamPlanning::PlanAggregate] the plan as stored
  # @raise [TeamPlanning::Error] "No such plan" unless the actor is an editor
  # @see TeamPlanning::PlanAggregate#set_scenario_period
  def set_scenario_period(plan_id, scenario_id, ends_on:, starts_on: nil)
    @repository.with_plan(plan_id) do |plan|
      authorize_plan!(:update?, plan)
      plan.set_scenario_period(scenario_id, ends_on:, starts_on:, set_by_id: actor_id!)
    end
  end

  # A block, when given, finds the conflicts under the plan's lock, so a change
  # made since the preview can't slip past. It isn't called once the base has
  # moved, so the refusal names the move, nor on an archived plan, which reads no drift.
  #
  # @param plan_id [String]
  # @param conflicts [Array<Hash>] used when no block is given
  # @yieldparam plan [TeamPlanning::PlanAggregate] under the plan's lock, once the actor may edit it
  # @yieldreturn [Array<Hash>] the conflicts, as {TeamPlanning::PlanAggregate#rebase} takes them
  # @return [TeamPlanning::PlanAggregate] the plan as stored
  # @raise [TeamPlanning::Error] "No such plan" unless the actor is an editor
  # @see TeamPlanning::PlanAggregate#rebase
  def rebase_plan(plan_id, base_on:, expected_base_on:, conflicts: [])
    @repository.with_plan(plan_id) do |plan|
      authorize_plan!(:update?, plan)
      conflicts = yield(plan) if block_given? && !plan.archived? && plan.base_on.to_s == expected_base_on.to_s
      plan.rebase(base_on:, expected_base_on:, conflicts:, rebased_by_id: actor_id!)
    end
  end

  # @param plan_id [String]
  # @param scenario_id [String]
  # @return [TeamPlanning::PlanAggregate] the plan as stored
  # @raise [TeamPlanning::Error] "No such plan" unless the actor is an editor
  # @see TeamPlanning::PlanAggregate#remove_scenario
  def remove_scenario(plan_id, scenario_id)
    @repository.with_plan(plan_id) do |plan|
      authorize_plan!(:update?, plan)
      plan.remove_scenario(scenario_id, removed_by_id: actor_id!)
    end
  end

  # @param plan_id [String]
  # @param scenario_id [String]
  # @param today [Date] as a UTC date
  # @return [TeamPlanning::PlanAggregate] the plan as stored
  # @raise [TeamPlanning::Error] "No such plan" unless the actor is an editor
  # @see TeamPlanning::PlanAggregate#close_step
  def close_step(plan_id, scenario_id, today: Time.now.utc.to_date)
    @repository.with_plan(plan_id) do |plan|
      authorize_plan!(:update?, plan)
      plan.close_step(scenario_id, today:, closed_by_id: actor_id!)
    end
  end

  # @param plan_id [String]
  # @param scenario_id [String]
  # @return [TeamPlanning::PlanAggregate] the plan as stored
  # @raise [TeamPlanning::Error] "No such plan" unless the actor is an editor
  # @see TeamPlanning::PlanAggregate#reopen_step
  def reopen_step(plan_id, scenario_id)
    @repository.with_plan(plan_id) do |plan|
      authorize_plan!(:update?, plan)
      plan.reopen_step(scenario_id, reopened_by_id: actor_id!)
    end
  end

  # @param plan_id [String]
  # @param kind [Class<TeamPlanning::Events::Change>]
  # @param scenario_id [String]
  # @param subject_id [String]
  # @param end_state [Hash] the kind's own fields
  # @param note [String, nil] why, sealed under the subject's key
  # @return [TeamPlanning::PlanAggregate] the plan as stored
  # @yieldparam plan [TeamPlanning::PlanAggregate] under the plan's lock, once the actor may edit it
  # @raise [TeamPlanning::Error] "No such plan" unless the actor is an editor
  # @see TeamPlanning::PlanAggregate#set_change
  def set_change(plan_id, kind, scenario_id:, subject_id:, end_state: {}, note: nil, &check)
    @repository.with_plan(plan_id) do |plan|
      authorize_plan!(:update?, plan)
      ensure_pay_right!(plan, facet_set_by(kind, end_state))
      plan.set_change(kind, scenario_id:, subject_id:, set_by_id: actor_id!, end_state:, note:, &check)
    end
  end

  # Records the changes the block returns in one write, so they land together
  # or not at all. The block works them out under the plan's lock, so they
  # can't race another edit.
  #
  # @param plan_id [String]
  # @yieldparam plan [TeamPlanning::PlanAggregate] under the plan's lock, once the actor may edit it
  # @yieldreturn [Array<Hash>] each `{ kind:, scenario_id:, subject_id:, end_state:, note: }`, the note optional
  # @return [TeamPlanning::PlanAggregate] the plan as stored
  # @raise [TeamPlanning::Error] "No such plan" unless the actor is an editor
  # @see TeamPlanning::PlanAggregate#set_change
  def set_changes(plan_id)
    @repository.with_plan(plan_id) do |plan|
      authorize_plan!(:update?, plan)
      yield(plan).each do |change|
        ensure_pay_right!(plan, facet_set_by(change.fetch(:kind), change.fetch(:end_state, {})))
        plan.set_change(change.fetch(:kind), scenario_id: change.fetch(:scenario_id), subject_id: change.fetch(:subject_id),
                                             set_by_id: actor_id!, end_state: change.fetch(:end_state, {}), note: change[:note])
      end
    end
  end

  # Hands one facet of one subject back to the scenario's parent.
  #
  # @param plan_id [String]
  # @param scenario_id [String]
  # @param subject_id [String]
  # @param facet [String] the second half of the change's key, such as "rule:<name>"
  # @return [TeamPlanning::PlanAggregate] the plan as stored
  # @raise [TeamPlanning::Error] "No such plan" unless the actor is an editor
  # @yieldparam plan [TeamPlanning::PlanAggregate] for the operation's scope check, run before the others
  # @see TeamPlanning::PlanAggregate#clear_change
  def clear_change(plan_id, scenario_id:, subject_id:, facet:, &check)
    @repository.with_plan(plan_id) do |plan|
      authorize_plan!(:update?, plan)
      check&.call(plan)
      ensure_pay_right!(plan, facet.to_s)
      ensure_line_money_right!(plan, scenario_id, subject_id, facet.to_s)
      plan.clear_change(scenario_id:, subject_id:, facet: facet.to_s, cleared_by_id: actor_id!)
    end
  end

  # Keeps what a scenario inherits for one facet of one subject, as it
  # resolves now.
  #
  # A change in the parent's chain is kept as it was made. With none, the
  # value comes from the baseline, read off the parent's resolved map by the
  # kind that holds the facet.
  #
  # @param plan_id [String]
  # @param scenario_id [String]
  # @param subject_id [String]
  # @param facet [String]
  # @param note [String, nil] why the scenario keeps it, sealed under the subject's key
  # @return [TeamPlanning::PlanAggregate] the plan as stored
  # @raise [TeamPlanning::Error] "No such plan" unless the actor is an editor; or if nothing can be pinned
  # @see TeamPlanning::PlanAggregate#pin_change
  def pin_change(plan_id, scenario_id:, subject_id:, facet:, note: nil)
    facet = facet.to_s
    @repository.with_plan(plan_id) do |plan|
      authorize_plan!(:update?, plan)
      ensure_pay_right!(plan, facet)
      plan.ensure_pinnable!(scenario_id, [ subject_id, facet ])
      kind, end_state, pinned_from = inherited(plan, scenario_id, subject_id, facet)
      plan.pin_change(kind, scenario_id:, subject_id:, facet:, end_state:, pinned_from:, pinned_by_id: actor_id!, note:)
    end
  end

  # Settles a conflict an update to today carried forward in a scenario.
  # Keeping the plan restates the change that conflicts, pinning it where the
  # scenario inherits a value the plan holds in clear, and keeps its note
  # unless given another. Following
  # reality sets what the Org Graph holds today in this scenario alone.
  #
  # @param plan_id [String]
  # @param scenario_id [String]
  # @param subject_id [String]
  # @param facet [String]
  # @param choice [String] "plan" or "reality"
  # @param note [String, nil] why; for keeping the plan, blank keeps the change's own
  # @param today [Date] as a UTC date
  # @return [TeamPlanning::PlanAggregate] the plan as stored
  # @raise [TeamPlanning::Error] "No such plan" unless the actor is an editor; or if there is nothing to settle
  # @see TeamPlanning::PlanAggregate#settle_conflict
  def settle_conflict(plan_id, scenario_id:, subject_id:, facet:, choice:, note: nil, today: Time.now.utc.to_date)
    key = [ subject_id, facet.to_s ]
    @repository.with_plan(plan_id) do |plan|
      authorize_plan!(:update?, plan)
      ensure_pay_right!(plan, key.last)
      ensure_line_money_right!(plan, scenario_id, *key)
      plan.ensure_settleable!(scenario_id, key)
      change = plan.winning_changes(scenario_id).fetch(key)
      if choice.to_s == "reality" && change.is_a?(TeamPlanning::Events::UnitSuccessionSet)
        raise TeamPlanning::Error, "A succession can't follow reality yet, as the units it retires wouldn't follow: change it on the map"
      end

      kind, end_state = choice.to_s == "reality" ? followable(*todays(plan, change, today)) : [ change.class, kept(change) ]
      if kind == TeamPlanning::Events::DepartureWithdrawn && end_state[:left]
        raise TeamPlanning::Error, "The Org Graph has this person leaving, so a withdrawn departure can't follow reality. You can still keep the plan"
      end
      from_id, = plan.inherited_change(scenario_id, key) unless scenario_id == plan.plan_id
      note = note.presence || note_of(change) if choice.to_s == "plan"
      plan.settle_conflict(kind, scenario_id:, subject_id:, facet: key.last, choice: choice.to_s, end_state:, settled_by_id: actor_id!,
                                 pinned_from: (from_id && [ from_id, change.event_id ]), note:)
    end
  end

  # Writes, rewrites or clears the note on a change or pin that stands in a scenario.
  #
  # @param plan_id [String]
  # @param scenario_id [String]
  # @param event_id [String] the change's or pin's event id, from the scenario's history
  # @param note [String, nil] blank clears it
  # @return [TeamPlanning::PlanAggregate] the plan as stored
  # @raise [TeamPlanning::Error] "No such plan" unless the actor is an editor
  # @see TeamPlanning::PlanAggregate#note_change
  def note_change(plan_id, scenario_id:, event_id:, note:)
    @repository.with_plan(plan_id) do |plan|
      authorize_plan!(:update?, plan)
      ensure_pay_right!(plan, plan.facet_of(scenario_id, event_id))
      ensure_note_right!(plan, plan.facet_of(scenario_id, event_id))
      plan.note_change(scenario_id:, event_id:, note:, noted_by_id: actor_id!)
    end
  end

  # Moves a scenario's change of a place, a position or a departure to the
  # step before or after it on the timeline. None of those is pay, so it
  # needs no see-pay right.
  #
  # @param plan_id [String]
  # @param scenario_id [String]
  # @param subject_id [String]
  # @param facet [String]
  # @param direction [String] "earlier" or "later"
  # @param to_scenario_id [String, nil] the step later, when more than one follows
  # @yieldparam plan [TeamPlanning::PlanAggregate] under the lock, once the actor may edit it
  # @yieldparam change [TeamPlanning::Events::Change, nil] the change in effect that moves
  # @yieldparam step_id [String] where it is checked: the step it leaves, then
  #   the one it reaches, once moved
  # @return [String] the step the change moved to
  # @raise [TeamPlanning::Error] "No such plan" unless the actor is an editor
  # @see TeamPlanning::PlanAggregate#move_change
  def move_change(plan_id, scenario_id:, subject_id:, facet:, direction:, to_scenario_id: nil, &check)
    moved_to = nil
    @repository.with_plan(plan_id) do |plan|
      authorize_plan!(:update?, plan)
      key = [ subject_id, facet ]
      check&.call(plan, plan.changes_in(scenario_id).reverse_each.find { it.key == key }, scenario_id) if plan.scenario?(scenario_id)
      moved_to = plan.move_change(scenario_id:, subject_id:, facet:, direction:, to_scenario_id:, moved_by_id: actor_id!)
      check&.call(plan, plan.changes_in(moved_to).reverse_each.find { it.key == key }, moved_to)
    end
    moved_to
  end

  # Takes back a change, pin or clear in a scenario. Without an event id, takes
  # back the actor's own latest one that can be undone, as an Undo button does.
  #
  # @param plan_id [String]
  # @param scenario_id [String]
  # @param event_id [String, nil] the change's event id, from the scenario's history
  # @yieldparam plan [TeamPlanning::PlanAggregate] under the lock, once the actor may edit it
  # @yieldparam restored [TeamPlanning::Events::Change, nil] the scenario's own change in effect once the entry is undone
  # @return [String] the event id undone
  # @raise [TeamPlanning::Error] "No such plan" unless the actor is an editor; or if there is nothing to undo
  # @see TeamPlanning::PlanAggregate#undo_change
  def undo_change(plan_id, scenario_id:, event_id: nil, &check)
    reverse(plan_id, scenario_id, event_id, :last_undoable_by, "You have nothing here to undo") do |plan, id|
      check&.call(plan, plan.restored_by_undo(scenario_id, id))
      ensure_line_money_right_on!(plan, scenario_id, id)
      plan.undo_change(scenario_id:, event_id: id, undone_by_id: actor_id!)
    end
  end

  # Restores an undone change, pin or clear in a scenario. Without an event id,
  # restores what the actor's own latest undo took back, as a Redo button does.
  #
  # @param plan_id [String]
  # @param scenario_id [String]
  # @param event_id [String, nil] the undone change's event id
  # @yieldparam plan [TeamPlanning::PlanAggregate] under the lock, once the actor may edit it
  # @yieldparam entry [RubyEventStore::Event, nil] the change, pin or clear about to be redone, nil for one not in the log
  # @return [String] the event id redone
  # @raise [TeamPlanning::Error] "No such plan" unless the actor is an editor; or if there is nothing to redo
  # @see TeamPlanning::PlanAggregate#redo_change
  def redo_change(plan_id, scenario_id:, event_id: nil, &check)
    reverse(plan_id, scenario_id, event_id, :last_redoable_by, "You have nothing here to redo") do |plan, id|
      check&.call(plan, plan.log_of(scenario_id).find { it.event_id == id })
      ensure_line_money_right_on!(plan, scenario_id, id)
      plan.redo_change(scenario_id:, event_id: id, redone_by_id: actor_id!)
    end
  end

  private

  def reverse(plan_id, scenario_id, event_id, pick, nothing)
    chosen = nil
    @repository.with_plan(plan_id) do |plan|
      authorize_plan!(:update?, plan)
      chosen = event_id.presence || plan.public_send(pick, scenario_id, actor_id!, except_facets: untouchable_facets(plan),
                                                                                  except_keys: untouchable_lines(plan, scenario_id)) or
        raise TeamPlanning::Error, nothing
      ensure_pay_right!(plan, plan.facet_of(scenario_id, chosen))
      yield plan, chosen
    end
    chosen
  end

  def standing_ids(plan, scenario_id) = TeamPlanning::SplitNeeds.standing_ids(context: @actor, aggregate: plan, scenario_id:)

  def inherited(plan, scenario_id, subject_id, facet)
    if TeamPlanning::ChangeKinds.holding(facet).any?(&:seals_end_state?)
      raise TeamPlanning::Error, "This holds a value the plan keeps private, which can't be pinned yet: set it in this scenario instead"
    end

    from_id, change = plan.inherited_change(scenario_id, [ subject_id, facet ])
    return [ change.class, change.data.except(*TeamPlanning::Events::Change::FIELDS), [ from_id, change.event_id ] ] if change

    kinds = TeamPlanning::ChangeKinds.holding(facet).select(&:readable?)
    raise TeamPlanning::Error, "This can't be pinned to the baseline yet" if kinds.empty?

    parent_id = plan.scenarios.fetch(scenario_id) { raise TeamPlanning::Error, "The baseline inherits nothing to pin" }.parent_id
    map = TeamPlanning::Resolution.new(context: @actor, plan: TeamPlanningPlan.find(plan.plan_id), scenario_id: parent_id).structure
    kinds.each do |kind|
      end_state = kind.read_from(map, subject_id:, facet:)
      return [ kind, end_state, nil ] if end_state
    end
    raise TeamPlanning::Error, "The baseline doesn't hold this"
  end

  # The aggregate holds a change without its sealed values, so they are read
  # off the stored event, to be sealed again as the restated change is written.
  def kept(change)
    stored = @repository.sealed({ change.key => change }).fetch(change.key)
    stored.data.except(*TeamPlanning::Events::Change::FIELDS).transform_values { it.is_a?(Shreddable::Value) ? it.reveal : it }
  end

  # A note is rewritten apart from its change, so it is read off the override.
  def note_of(change)
    sealed = TeamPlanningOverride.find_by(event_id: change.event_id)&.note or return nil
    Operations::TeamPlanning::MapPayload.sealed(sealed)[:value]
  end

  # What the Org Graph holds today for a change's key, read by the first kind
  # sharing its facet that finds it, as a person staying reads as a departure
  # withdrawn.
  # The Org Graph can hold what no change kind can, so that is refused.
  def followable(kind, end_state)
    kind.followed_end_state(end_state.to_h.symbolize_keys)
    [ kind, end_state ]
  rescue TeamPlanning::Error
    raise TeamPlanning::Error, "The Org Graph holds a value this plan can't hold yet, so this can't follow reality. You can still keep the plan"
  end

  def todays(plan, change, today)
    now = TeamPlanning::Baseline.new(context: @actor, plan: TeamPlanningPlan.find(plan.plan_id)).map_on(today, history: true)
    kinds = [ change.class ] | TeamPlanning::ChangeKinds.holding(change.key.last).select(&:readable?)
    kinds.each do |kind|
      end_state = kind == change.class ? kind.read_org_graph(now, change) : kind.read_from(now, subject_id: change.data[:subject_id], facet: change.key.last)
      return [ kind, end_state ] if end_state
    end
    raise TeamPlanning::Error, "The Org Graph doesn't hold this today, so there is nothing to follow"
  end

  # Someone who has left may still be made a viewer of a plan they are in, so
  # an editor can step a former co-editor down; nobody gone, and nobody
  # without an account here, joins or edits.
  def ensure_can_join!(plan, person_id, role)
    return if PlanPolicy.reachable_ids([ person_id ]).any?
    return if role.to_s == "viewer" && plan.member?(person_id)

    raise TeamPlanning::Error, "Only someone active in this organisation, with an account here, can join a plan"
  end

  # The stream counts an editor who has since left; this counts only those
  # who can still open the plan, so nobody hands it to someone gone.
  def ensure_reachable_editor_remains!(plan, person_id)
    return unless plan.role_of(person_id) == "editor"
    return if PlanPolicy.reachable_ids(plan.editor_ids - [ person_id ]).any?

    raise TeamPlanning::Error, TeamPlanning::PlanAggregate::EDITOR_NEEDED.fetch(plan.archived? ? :archived : :open)
  end

  # The stream counts a holder who has since left; this counts only those who
  # can still open the plan, so pay never ends up with nobody who can grant it.
  def ensure_reachable_holder_remains!(plan, person_id)
    return unless plan.sees_pay?(person_id)
    return if PlanPolicy.reachable_ids(plan.pay_holder_ids - [ person_id ]).any?

    raise TeamPlanning::Error, TeamPlanning::PlanAggregate::PAY_HOLDER_NEEDED.fetch(plan.archived? ? :archived : :open)
  end

  # Pay is changed, cleared, noted, undone and redone only by a member who
  # may see it, as each of those reads or moves what a seat costs.
  def ensure_pay_right!(plan, facet)
    return unless facet == TeamPlanning::Events::PlanDataSet::PAY_FACET
    return if PlanPolicy.new(@actor, plan).see_pay?

    raise TeamPlanning::Error, "Only a member with the see-pay right can change pay"
  end

  def untouchable_facets(plan) = PlanPolicy.new(@actor, plan).see_pay? ? [] : [ TeamPlanning::Events::PlanDataSet::PAY_FACET ]

  def untouchable_lines(plan, scenario_id) = PlanPolicy.new(@actor, plan).see_pay? ? Set.new : TeamPlanning::LineMoney.priced_keys(plan, scenario_id)

  # A budget line's amount is pay ([#367](https://github.com/espaliahq/espalia/issues/367)).
  def ensure_line_money_right!(plan, scenario_id, subject_id, facet)
    return if PlanPolicy.new(@actor, plan).see_pay?
    return unless TeamPlanning::LineMoney.priced?(plan, scenario_id, subject_id, facet)

    raise TeamPlanning::Error, TeamPlanning::LineMoney::REFUSAL
  end

  # Checked after the operation's own scope check, so a line the plan hides reads as it always has.
  def ensure_line_money_right_on!(plan, scenario_id, event_id)
    entry = plan.log_of(scenario_id).find { it.event_id == event_id } or return

    ensure_line_money_right!(plan, scenario_id, entry.data[:subject_id], plan.facet_of(scenario_id, event_id))
  end

  # A note is free text and may state a line's amount, so a note on any
  # budget-line change needs the right, amount or not.
  def ensure_note_right!(plan, facet)
    return unless facet == TeamPlanning::LineMoney::FACET
    return if PlanPolicy.new(@actor, plan).see_pay?

    raise TeamPlanning::Error, "Noting a budget line change needs the see-pay right."
  end

  def facet_set_by(kind, end_state)
    "#{kind.facet}:#{end_state.to_h.symbolize_keys[:field]}" if kind == TeamPlanning::Events::PlanDataSet
  end

  # A plan is private to its members, so to anyone else it reads as missing:
  # the refusal can't tell a caller which plan ids exist.
  def authorize_plan!(predicate, plan)
    return if plan.exists? && PlanPolicy.new(@actor, plan).public_send(predicate)

    raise TeamPlanning::Error, "No such plan"
  end

  def authorize!(predicate, record)
    return if PlanPolicy.new(@actor, record).public_send(predicate)

    raise Pundit::NotAuthorizedError, yield
  end

  # A unit retired since the plan chose it may stay, so widening never asks to drop it.
  # Postgres reads a UUID without its hyphens too, so only the hyphenated form
  # is taken: the plan compares the ids it keeps as written.
  def known_units!(unit_ids, kept: [])
    unit_ids = Array(unit_ids).map { it.to_s.strip.downcase }.compact_blank.uniq
    return unit_ids if unit_ids.all?(OrgGraph::StructureAggregate::UUID) && OrgUnit.live.where(id: unit_ids - kept).count == (unit_ids - kept).size

    raise TeamPlanning::Error, "A plan covers units the organisation has"
  end

  # Without key material nothing can be sealed, so the plan archives with
  # today's prices, as one archived before the copy existed does.
  def frozen_prices = (TeamPlanning::PricingInputs.capture(ActsAsTenant.current_tenant) if PlanKeyStore.available?)

  def actor_id!
    @actor.person&.id or raise TeamPlanning::Error, "Link your account to a person to work on plans"
  end
end
