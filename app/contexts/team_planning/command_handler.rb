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
  # @return [TeamPlanning::PlanAggregate] the plan as stored
  # @raise [Pundit::NotAuthorizedError] unless the actor may create a plan
  # @see TeamPlanning::PlanAggregate#create
  def create_plan(plan_id, name:, base_on:)
    created_by_id = actor_id!
    authorize!(:create?, nil) { "Only a tenant admin or a planner can create a plan" }
    @repository.with_plan(plan_id) do |plan|
      plan.create(plan_id, name: name, base_on: base_on, created_by_id: created_by_id)
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
      plan.rename(name, renamed_by_id: actor_id!)
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
      plan.remove_member(person_id, removed_by_id: actor_id!)
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

  # @param plan_id [String]
  # @param scenario_id [String]
  # @param ends_on [Date, String]
  # @return [TeamPlanning::PlanAggregate] the plan as stored
  # @raise [TeamPlanning::Error] "No such plan" unless the actor is an editor
  # @see TeamPlanning::PlanAggregate#set_scenario_period
  def set_scenario_period(plan_id, scenario_id, ends_on:)
    @repository.with_plan(plan_id) do |plan|
      authorize_plan!(:update?, plan)
      plan.set_scenario_period(scenario_id, ends_on:, set_by_id: actor_id!)
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
  # @param kind [Class<TeamPlanning::Events::Change>]
  # @param scenario_id [String]
  # @param subject_id [String]
  # @param end_state [Hash] the kind's own fields
  # @return [TeamPlanning::PlanAggregate] the plan as stored
  # @raise [TeamPlanning::Error] "No such plan" unless the actor is an editor
  # @see TeamPlanning::PlanAggregate#set_change
  def set_change(plan_id, kind, scenario_id:, subject_id:, end_state: {})
    @repository.with_plan(plan_id) do |plan|
      authorize_plan!(:update?, plan)
      plan.set_change(kind, scenario_id:, subject_id:, set_by_id: actor_id!, end_state:)
    end
  end

  # Hands one facet of one subject back to the scenario's parent. Reconcile
  # (4.5) calls this to follow reality.
  #
  # @param plan_id [String]
  # @param scenario_id [String]
  # @param subject_id [String]
  # @param facet [String] the second half of the change's key, such as "rule:<name>"
  # @return [TeamPlanning::PlanAggregate] the plan as stored
  # @raise [TeamPlanning::Error] "No such plan" unless the actor is an editor
  # @see TeamPlanning::PlanAggregate#clear_change
  def clear_change(plan_id, scenario_id:, subject_id:, facet:)
    @repository.with_plan(plan_id) do |plan|
      authorize_plan!(:update?, plan)
      plan.clear_change(scenario_id:, subject_id:, facet: facet.to_s, cleared_by_id: actor_id!)
    end
  end

  # Keeps what a scenario inherits for one facet of one subject, as it
  # resolves now. Reconcile (4.5) calls this to keep the plan.
  #
  # A change in the parent's chain is kept as it was made. With none, the
  # value comes from the baseline, read off the parent's resolved map by the
  # kind that holds the facet.
  #
  # @param plan_id [String]
  # @param scenario_id [String]
  # @param subject_id [String]
  # @param facet [String]
  # @return [TeamPlanning::PlanAggregate] the plan as stored
  # @raise [TeamPlanning::Error] "No such plan" unless the actor is an editor; or if nothing can be pinned
  # @see TeamPlanning::PlanAggregate#pin_change
  def pin_change(plan_id, scenario_id:, subject_id:, facet:)
    facet = facet.to_s
    @repository.with_plan(plan_id) do |plan|
      authorize_plan!(:update?, plan)
      kind, end_state, pinned_from = inherited(plan, scenario_id, subject_id, facet)
      plan.pin_change(kind, scenario_id:, subject_id:, facet:, end_state:, pinned_from:, pinned_by_id: actor_id!)
    end
  end

  private

  def inherited(plan, scenario_id, subject_id, facet)
    from_id, change = plan.inherited_change(scenario_id, [ subject_id, facet ])
    return [ change.class, change.data.except(*TeamPlanning::Events::Change::FIELDS), [ from_id, change.event_id ] ] if change

    kind = TeamPlanning::ChangeKinds.holding(facet)
    raise TeamPlanning::Error, "This can't be pinned to the baseline yet" unless kind.readable?

    parent_id = plan.scenarios.fetch(scenario_id) { raise TeamPlanning::Error, "The baseline inherits nothing to pin" }.parent_id
    map = TeamPlanning::Resolution.new(context: @actor, plan: TeamPlanningPlan.find(plan.plan_id), scenario_id: parent_id).structure
    end_state = kind.read_from(map, subject_id:, facet:) or raise TeamPlanning::Error, "The baseline doesn't hold this"
    [ kind, end_state, nil ]
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

    raise TeamPlanning::Error, "A plan needs an editor: make someone else an editor first"
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

  def actor_id!
    @actor.person&.id or raise TeamPlanning::Error, "Link your account to a person to work on plans"
  end
end
