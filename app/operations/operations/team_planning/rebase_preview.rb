# frozen_string_literal: true

# What updating a plan to today would take in
# ([#263](https://github.com/espaliahq/espalia/issues/263)): the drift being
# taken in, counts of where each scenario's changes stand, and the conflicts
# the update would carry forward, read by `TeamPlanning::RebasePreview`.
# Walked by the privacy test and the forgotten-person audit.
class Operations::TeamPlanning::RebasePreview < Operations::Base
  include Operations::TeamPlanning::PlanRead

  description "Preview updating a Team Planning plan the caller is in to today (a UTC day), before " \
              "team_planning_rebase_plan does it. `drift` is what the update takes in: the from, to, changes " \
              "and names that team_planning_drift gives for the same base, in the same shape. " \
              "For the baseline (scenario_id equal to the plan_id) and each scenario, it counts the planned " \
              "changes reading done, pending and conflicting, as team_planning_status reads them. Once the base " \
              "is today a conflicting change would read pending, so `conflicts` names each one, by the scenario " \
              "it reads conflicting in, subject_id, facet and change_id: the update records them afresh, and " \
              "status keeps them conflicting. `names` gives each conflict's subject a name, as team_planning_status " \
              "names it. `starts` names the first step whose start the update moves, with its start now " \
              "(starts_on) and on today (will_start_on); a first step that starts after today keeps its start, " \
              "and the days before it stay as today. " \
              "Pass base_on to team_planning_rebase_plan. Refused when the plan already stands on today or on a " \
              "day still to come, when the plan is updated while the preview reads it, when the first step would end " \
              "before today, naming it, when the plan is archived, and, as an unknown plan, " \
              "unless the caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true

  # @return [Hash] `{ plan_id, base_on, to, scenarios, conflicts, names, starts, drift }`
  def perform
    plan = plan!
    raise Operations::Base::ParameterError, ::TeamPlanning::PlanAggregate::ARCHIVED if plan.archived?

    report = refusing_bad_plans { ::TeamPlanning::RebasePreview.new(context:, plan:).call }
    { plan_id: plan.id, base_on: report.base_on.iso8601, to: report.to.iso8601,
      scenarios: report.scenarios.map(&:to_h), conflicts: report.conflicts, names: report.names,
      starts: report.starts.map { { **it, starts_on: it[:starts_on].iso8601, will_start_on: it[:will_start_on].iso8601 } },
      drift: Operations::TeamPlanning::Drift.payload(report.drift) }
  end
end
