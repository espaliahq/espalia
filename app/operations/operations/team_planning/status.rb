# frozen_string_literal: true

# Where each of a scenario's planned changes stands against the Org Graph
# today ([#235](https://github.com/espaliahq/espalia/issues/235)), compared
# by `TeamPlanning::Status` on every read. A kind has a status only when it
# reads its end state off a map and the Org Graph can move its facet. Walked
# by the privacy test and the forgotten-person audit.
class Operations::TeamPlanning::Status < Operations::Base
  include Operations::TeamPlanning::PlanRead

  description "Get the status of each planned change in a scenario of a Team Planning plan the caller is in, " \
              "held against the Org Graph today (a UTC day, as known now). There is one status per subject and " \
              "facet the scenario resolves, from its own changes and those it inherits from the scenarios it " \
              "follows; scenario_id says which scenario made it (the plan_id is the baseline). 'done' when today " \
              "reads the planned end state, 'pending' when today still reads what the plan's base held or what " \
              "the step before plans, 'conflicting' when it reads none of these; before the plan's base date " \
              "nothing reads conflicting. A person's placements are one facet, so a placement list is " \
              "done only when the whole list matches. The Org Graph can't say which position someone fills, only " \
              "where they are, so a placement in a position is done once the person is in the position's unit at " \
              "its allocation, with its role only when the plan names one. A change the Org Graph never holds, " \
              "such as a rule or a position, has no status: it would read pending forever. A unit retirement is " \
              "done once the Org Graph has retired the unit. A unit succession is held against every succession " \
              "the Org Graph recorded since the base that shares a planned predecessor, joined: done when they " \
              "join to the planned sides, conflicting when they don't. A departure is done once the Org Graph has " \
              "the person leave, and pending while they stay. Subjects are named by id, and `names` maps each the Org Graph " \
              "holds to a name; a forgotten person reads as \"#{Person::FORMER_MEMBER}\", and a subject only the " \
              "plan holds has none. Refused, as an unknown plan, unless " \
              "the caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "The scenario, or the plan's id for the baseline." }

  # @return [Hash] `{ plan_id, scenario_id, on, statuses, names }`
  def perform
    plan = plan!
    scenario_id = scenario_id!(:scenario_id)
    report = refusing_bad_plans { ::TeamPlanning::Status.new(context:, plan:, scenario_id:).call }
    { plan_id: plan.id, scenario_id:, on: report.on.iso8601,
      statuses: report.statuses.map { it.to_h.merge(status: it.status.to_s) },
      names: report.names }
  end
end
