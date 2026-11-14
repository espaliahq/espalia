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
    winning = @repository.load_plan(@plan.id).winning_changes(@scenario_id).values
    resolved = winning.reduce(@baseline.structure) { |map, change| change.class.apply_to(map, change.data) }
    explained(resolved.settled)
  end

  private

  # A person off the map either left by the base date, or was forgotten, or
  # joined after it.
  def explained(map)
    return map if map.unresolved.empty?

    ids = map.unresolved.map(&:person_id)
    left = OrgLeaver.where(tenant_id: @plan.tenant_id, person_id: ids).where(left_on: ..map.base_on).pluck(:person_id) +
           ::Person.where(tenant_id: @plan.tenant_id, id: ids).where.not(forgotten_at: nil).pluck(:id)
    map.with(unresolved: map.unresolved.map { it.with(why: left.include?(it.person_id) ? it.class::LEFT : it.class::JOINED_LATER) })
  end
end
