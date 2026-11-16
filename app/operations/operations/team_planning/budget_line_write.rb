# frozen_string_literal: true

# What the tools that set or cut a scenario's budget line share. The
# baseline holds the organisation's approved budget as it is, so only a
# scenario changes it.
module Operations::TeamPlanning::BudgetLineWrite
  extend ActiveSupport::Concern
  include Operations::TeamPlanning::ChangeWrite
  include Operations::TeamPlanning::PlanRead

  BASELINE = "The baseline holds the organisation's approved budget as it is: change a line in a scenario"
  NO_SUCH_LINE = "This scenario has no such budget line"
  AMOUNT_NEEDS_PAY = "Setting a budget amount needs the see-pay right."
  MONEY_FIELDS = %i[amount currency period].freeze
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
  def line_changes(line_id, plan = loaded_plan)
    chain = refusing_bad_plans { plan.resolution_chain(scenario_id!(:scenario_id)) }
    chain.flat_map { plan.changes_in(it) }.select { it.key == [ line_id, FACET ] }
  end

  # The plan as it stands before the lock, for the checks that shape the end state.
  def loaded_plan = @loaded_plan ||= refusing_bad_plans { ::TeamPlanning::Repository.new.load_plan(plan_id!) }

  # A tenant line the organisation has since removed stays one, so it keeps reading as orphaned.
  #
  # @return [Boolean] whether the id names one of the organisation's lines
  def tenant_line?(line_id, prior = nil) = prior&.data&.dig(:tenant_line) == true || ::BudgetLine.exists?(id: line_id)

  # Refuses a line the scenario doesn't hold: neither the organisation's nor one this plan set or cut along its
  # chain, or one outside a scoped plan's cost centres. Both read the same, so a member can't use a write to learn
  # that an outside line exists ([#378](https://github.com/espaliahq/espalia/issues/378)).
  def held!(plan, line_id)
    return if (tenant_line?(line_id) || winning_change(plan, line_id, FACET)) && !outside_line?(plan, line_id)

    raise Operations::Base::ParameterError, NO_SUCH_LINE
  end

  # A budget line's amount is pay ([#367](https://github.com/espaliahq/espalia/issues/367)): a line that carries
  # one is read-only to a member without the see-pay right. Checked after {#held!}, so a hidden line reads as
  # missing first.
  def line_money!(plan, line_id)
    return if see_pay?
    return unless ::TeamPlanning::LineMoney.priced?(plan, scenario_id!(:scenario_id), line_id, FACET)

    raise Operations::Base::ParameterError, ::TeamPlanning::LineMoney::REFUSAL
  end

  # A member without the see-pay right may give a line a head count only.
  def no_money_given!
    return if see_pay? || MONEY_FIELDS.none? { params[it].present? }

    raise Operations::Base::ParameterError, AMOUNT_NEEDS_PAY
  end

  def see_pay? = PlanPolicy.new(context, TeamPlanningPlan.find(plan_id!)).see_pay?

  # Judged as {WithinScope#lines_within_scope!} judges it under the lock.
  def outside_line?(plan, line_id)
    record = TeamPlanningPlan.find(plan.plan_id)
    return false if record.scope_unit_ids.blank?

    map, = ::TeamPlanning::Resolution.new(context:, plan: record, scenario_id: scenario_id!(:scenario_id)).resolved(plan)
    line_outside?(plan, map, scenario_id!(:scenario_id), line_id)
  end
end
