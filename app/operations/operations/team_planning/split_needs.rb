# frozen_string_literal: true

# What each change in a scenario would need to move into an agreed part
# alone, read before team_planning_split_scenario by `TeamPlanning::SplitNeeds`
# ([#360](https://github.com/espaliahq/espalia/issues/360)). It names changes
# by subject and facet and never shows an end state, so pay reads as its facet
# alone. Walked by the privacy test and the forgotten-person audit.
class Operations::TeamPlanning::SplitNeeds < Operations::Base
  include Operations::TeamPlanning::PlanRead

  description "Before team_planning_split_scenario, list what each change in a scenario of a Team Planning plan the " \
              "caller is in would need to move into the agreed part. There is one entry per subject and facet the " \
              "scenario itself changes, oldest first, with the event_id to pass to the split; moving it takes every " \
              "earlier change to the same subject and facet along. `needs` lists the changes that create something " \
              "it refers to and would stay, by subject_id, facet and the event_id to move across too; a need with a " \
              "null event_id has no change in effect, so the entry can't move. A choice in which every entry's needs " \
              "are chosen as well splits. No end state is shown. Subjects are named by id, and `names` maps those " \
              "the Org Graph holds to a name, as team_planning_status does; a forgotten person reads as " \
              "\"#{Person::FORMER_MEMBER}\". Refused for the baseline (scenario_id equal to the plan_id) and, as an " \
              "unknown plan, unless the caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true

  # @return [Hash] `{ plan_id, scenario_id, changes: [{ event_id, subject_id, facet, needs }], names }`
  def perform
    plan = plan!
    scenario_id = scenario_id!(:scenario_id)
    report = refusing_bad_plans { ::TeamPlanning::SplitNeeds.new(context:, plan:, scenario_id:).call }
    { plan_id: plan.id, scenario_id:, changes: report.changes.map { it.to_h.merge(needs: it.needs.map(&:to_h)) }, names: report.names }
  end
end
