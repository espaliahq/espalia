# frozen_string_literal: true

# The organisation a plan stands on
# ([#210](https://github.com/espaliahq/espalia/issues/210)). It and
# `team_planning_plan` are walked by the privacy test and the forgotten-person
# audit.
class Operations::TeamPlanning::Baseline < Operations::Base
  include Operations::TeamPlanning::PlanRead
  include Operations::TeamPlanning::MapPayload

  description "Get the baseline of a Team Planning plan the caller is in: the organisation on the plan's base " \
              "date, as known at the end of the day before. Units carry their parent, level and owners; people " \
              "carry their facts that day and each unit they hold, with allocation and role. People are named " \
              "by id, and `names` maps every person id the map uses to a name; a forgotten person " \
              "reads as \"#{Person::FORMER_MEMBER}\". Refused, as an unknown plan, unless the caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true

  # @return [Hash] `{ plan_id, base_on, known_on, units, people, unassigned_ids, positions, unresolved, departed, names }`
  def perform
    plan = plan!
    { plan_id: plan.id, **map_payload(::TeamPlanning::Baseline.new(context:, plan:).call, plan:) }
  end
end
