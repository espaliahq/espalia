# frozen_string_literal: true

# One scenario's organisation, resolved and never stored: the plan's
# {TeamPlanning::Baseline}, then the changes of each scenario along the
# scenario's {TeamPlanning::PlanAggregate#resolution_chain}. The last change
# for a subject and facet wins, so changes to different facets never compete.
#
# Like the baseline, {#structure} is ids only and {#call} joins the names last.
#
# @example
#   TeamPlanning::Resolution.new(context:, plan:, scenario_id: lean_q1).call
class TeamPlanning::Resolution
  # @param context [AuthorizationContext]
  # @param plan [TeamPlanningPlan]
  # @param scenario_id [String] the plan's id for the root
  # @param repository [TeamPlanning::Repository]
  def initialize(context:, plan:, scenario_id:, repository: TeamPlanning::Repository.new)
    @baseline = TeamPlanning::Baseline.new(context:, plan:)
    @plan = plan
    @scenario_id = scenario_id
    @repository = repository
  end

  # @return [TeamPlanning::Baseline::Map] with names joined
  # @raise [Pundit::NotAuthorizedError] when the caller can't open the plan or see the Org Graph
  # @raise [TeamPlanning::Error] for a scenario the plan doesn't have
  def call = @baseline.named(structure)

  # @return [TeamPlanning::Baseline::Map] by id, with no names
  # @raise [Pundit::NotAuthorizedError] when the caller can't open the plan or see the Org Graph
  # @raise [TeamPlanning::Error] for a scenario the plan doesn't have
  def structure
    map = @baseline.structure
    winning_changes.reduce(map) { |resolved, change| change.class.apply_to(resolved, change.data) }
  end

  private

  def winning_changes
    plan = @repository.load_plan(@plan.id)
    plan.resolution_chain(@scenario_id)
      .flat_map { plan.changes_in(it) }
      .each_with_object({}) { |change, latest| latest.delete(change.key); latest[change.key] = change }
      .values
  end
end
