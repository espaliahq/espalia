# frozen_string_literal: true

# What the tools that set or cut a scenario's budget line share. The
# baseline holds the organisation's approved budget as it is, so only a
# scenario changes it.
module Operations::TeamPlanning::BudgetLineWrite
  extend ActiveSupport::Concern
  include Operations::TeamPlanning::ChangeWrite
  include Operations::TeamPlanning::PlanRead

  BASELINE = "The baseline holds the organisation's approved budget as it is: change a line in a scenario"
  FACET = ::TeamPlanning::Events::BudgetLineSet.facet

  private

  # The handler checks the plan again under the lock; checking first keeps every other refusal behind it.
  def scenario!
    plan!(:update?)
    scenario_id = scenario_id!(:scenario_id)
    raise Operations::Base::ParameterError, BASELINE if scenario_id == plan_id!

    scenario_id
  end

  # Read before the lock, to shape the end state; {#held!} checks again under it.
  #
  # @return [Array<TeamPlanning::Events::Change>] the sets and cuts in effect for the line along the scenario's
  #   chain, oldest first, so the last is the one the scenario resolves to
  def line_changes(line_id)
    plan = refusing_bad_plans { ::TeamPlanning::Repository.new.load_plan(plan_id!) }
    chain = refusing_bad_plans { plan.resolution_chain(scenario_id!(:scenario_id)) }
    chain.flat_map { plan.changes_in(it) }.select { it.key == [ line_id, FACET ] }
  end

  # A tenant line the organisation has since removed stays one, so it keeps reading as orphaned.
  #
  # @return [Boolean] whether the id names one of the organisation's lines
  def tenant_line?(line_id, prior = nil) = prior&.data&.dig(:tenant_line) == true || ::BudgetLine.exists?(id: line_id)

  # Refuses a line the scenario doesn't hold: neither the organisation's nor one this plan set or cut along its chain.
  def held!(plan, line_id)
    return if tenant_line?(line_id) || winning_change(plan, line_id, FACET)

    raise Operations::Base::ParameterError, "This scenario has no such budget line"
  end
end
