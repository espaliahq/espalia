# frozen_string_literal: true

# Removes a scenario no other scenario forks from.
class Operations::TeamPlanning::RemoveScenario < Operations::Base
  include Operations::TeamPlanning::PlanWrite

  description "Remove a scenario from a Team Planning plan. It cannot be restored. Refused for the baseline, " \
              "for a scenario others fork from (remove those first), or unless the caller is one of its editors. " \
              "An editor without the see-pay right is told, as a count, how many of its changes are to pay or budget amounts."
  category :destructive

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true

  # Tells an editor who cannot see pay how many of the scenario's changes are
  # to pay or to a budget line's amount they cannot see, as a count only: the same entries status shows them.
  #
  # @param context [AuthorizationContext]
  # @param params [Hash] `{ plan_id, scenario_id }`
  # @return [String, nil]
  def self.approval_notice(context:, params:)
    params = params.to_h.with_indifferent_access
    scenario_id = params[:scenario_id].to_s.downcase
    approval_notices(context:, plan_id: params[:plan_id], scenario_ids: [ scenario_id ])[scenario_id]
  end

  # The approval notice for each of a plan's scenarios, loading the plan once,
  # so a page that offers several removals doesn't replay it for each.
  #
  # @param context [AuthorizationContext]
  # @param plan_id [String]
  # @param scenario_ids [Array<String>]
  # @return [Hash{String => String}] a notice by scenario id, only where one applies
  def self.approval_notices(context:, plan_id:, scenario_ids:)
    plan = TeamPlanningPlan.find_by(id: plan_id)
    return {} unless plan

    policy = PlanPolicy.new(context, plan)
    return {} if !policy.show? || policy.see_pay?

    aggregate = ::TeamPlanning::Repository.new.load_plan(plan.id)
    scenario_ids.map { it.to_s.downcase }.uniq.filter_map do |scenario_id|
      hidden = hidden_pay(aggregate, scenario_id)
      [ scenario_id, notice(hidden) ] if hidden.positive?
    end.to_h
  rescue ::TeamPlanning::Error
    {}
  end

  # A budget line's amount is pay too, so a change to a line that carries one
  # counts ([#441](https://github.com/espaliahq/espalia/pull/441)).
  def self.hidden_pay(aggregate, scenario_id)
    keys = aggregate.changes_in(scenario_id).map(&:key).uniq
    priced = keys.any? { it.last == ::TeamPlanning::LineMoney::FACET } ? ::TeamPlanning::LineMoney.priced_keys(aggregate, scenario_id) : Set.new
    keys.count { it.last == ::TeamPlanning::Events::PlanDataSet::PAY_FACET || priced.include?(it) }
  end
  private_class_method :hidden_pay

  def self.notice(hidden)
    "This scenario holds #{hidden} #{hidden == 1 ? "change" : "changes"} to pay or budget amounts you can't see. " \
      "Removing it removes #{hidden == 1 ? "that" : "those"} too."
  end
  private_class_method :notice

  # @return [Hash] `{ plan_id, scenario_id, removed }`
  def perform
    plan_id = plan_id!
    scenario_id = scenario_id!(:scenario_id)
    refusing_bad_plans { handler.remove_scenario(plan_id, scenario_id) }
    { plan_id:, scenario_id:, removed: true }
  end
end
