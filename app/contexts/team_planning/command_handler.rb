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
    authorize!(:create?, nil) { "Only a tenant admin can create a plan" }
    @repository.with_plan(plan_id) do |plan|
      plan.create(plan_id, name: name, base_on: base_on, created_by_id: actor_id!)
    end
  end

  # @param plan_id [String]
  # @param name [String]
  # @return [TeamPlanning::PlanAggregate] the plan as stored
  # @raise [TeamPlanning::Error] "No such plan" unless the actor created it
  # @see TeamPlanning::PlanAggregate#rename
  def rename_plan(plan_id, name)
    @repository.with_plan(plan_id) do |plan|
      authorize_plan!(:update?, plan)
      plan.rename(name, renamed_by_id: actor_id!)
    end
  end

  # @param plan_id [String]
  # @return [TeamPlanning::PlanAggregate] the plan as stored
  # @raise [TeamPlanning::Error] "No such plan" unless the actor created it
  # @see TeamPlanning::PlanAggregate#delete
  def delete_plan(plan_id)
    @repository.with_plan(plan_id) do |plan|
      authorize_plan!(:destroy?, plan)
      plan.delete(deleted_by_id: actor_id!)
    end
  end

  private

  # A plan is private to its creator, so to anyone else it reads as missing:
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
