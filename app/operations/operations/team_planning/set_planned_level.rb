# frozen_string_literal: true

# Plans a promotion: the level someone holds from a scenario's step on, as a
# LevelSet change [#270](https://github.com/espaliahq/espalia/issues/270). The
# level is what the plan says about that person, so it seals under their key
# in the plan, and forgetting them leaves it reading `{ removed: true }`. It
# wins over a level set with team_planning_set_plan_value, which corrects what
# the HRIS holds rather than planning a change. team_planning_clear_change
# drops it. Pinning one to a parent is refused for now.
class Operations::TeamPlanning::SetPlannedLevel < Operations::Base
  include Operations::TeamPlanning::ChangeWrite

  description "Plan a promotion in a scenario of a Team Planning plan: the level a person holds from this step on. " \
              "The plan keeps the level private to that person, so once they are forgotten it reads as removed. " \
              "A planned level wins over a level corrected with team_planning_set_plan_value. Refused unless the " \
              "caller is one of the plan's editors."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "The scenario, or the plan's id for the baseline." }
  parameter :person_id, String, required: true
  parameter :level, String, required: true, allow_blank: false, schema: { description: "The level, as the Org Graph names levels." }

  # @return [Hash] `{ plan_id, scenario_id, person_id, level }`
  def perform
    person_id = uuid!(:person_id)
    set_change!(::TeamPlanning::Events::LevelSet, subject_id: person_id, end_state: { level: params[:level] }) { known_person!(person_id) }

    { plan_id: plan_id!, scenario_id: scenario_id!(:scenario_id), person_id:, level: params[:level].strip }
  end

  private

  def known_person!(person_id)
    return if ::Person.exists?(tenant_id: ActsAsTenant.current_tenant&.id, id: person_id)

    raise Operations::Base::ParameterError, "No such person"
  end
end
