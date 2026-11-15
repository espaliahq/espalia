# frozen_string_literal: true

# Removes a scenario no other scenario forks from.
class Operations::TeamPlanning::RemoveScenario < Operations::Base
  include Operations::TeamPlanning::PlanWrite

  description "Remove a scenario from a Team Planning plan. It cannot be restored. Refused for the baseline, " \
              "for a scenario others fork from (remove those first), or unless the caller is one of its editors."
  category :destructive

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true

  # Tells an editor who cannot see pay how many of the scenario's changes are
  # pay they cannot see, as a count only: the same entries status shows them.
  #
  # @param context [AuthorizationContext]
  # @param params [Hash] `{ plan_id, scenario_id }`
  # @return [String, nil]
  def self.approval_notice(context:, params:)
    params = params.to_h.with_indifferent_access
    plan = TeamPlanningPlan.find_by(id: params[:plan_id])
    return unless plan

    policy = PlanPolicy.new(context, plan)
    return if !policy.show? || policy.see_pay?

    hidden = hidden_pay(::TeamPlanning::Repository.new.load_plan(plan.id), params[:scenario_id].to_s.downcase)
    return unless hidden.positive?

    "This scenario holds #{hidden} #{hidden == 1 ? "change" : "changes"} to pay you can't see. " \
      "Removing it removes #{hidden == 1 ? "that" : "those"} too."
  rescue ::TeamPlanning::Error
    nil
  end

  def self.hidden_pay(aggregate, scenario_id)
    aggregate.changes_in(scenario_id).map(&:key).uniq.count { it.last == ::TeamPlanning::Events::PlanDataSet::PAY_FACET }
  end
  private_class_method :hidden_pay

  # @return [Hash] `{ plan_id, scenario_id, removed }`
  def perform
    plan_id = plan_id!
    scenario_id = scenario_id!(:scenario_id)
    refusing_bad_plans { handler.remove_scenario(plan_id, scenario_id) }
    { plan_id:, scenario_id:, removed: true }
  end
end
