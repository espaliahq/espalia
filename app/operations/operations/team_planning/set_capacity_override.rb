# frozen_string_literal: true

# A planner's capacity figure for one of a person's places, in place of the
# one their capacity model works out, as a CapacitySet change
# ([#284](https://github.com/espaliahq/espalia/issues/284)). The figure is the
# plan's judgement about that person, so it seals under their key in the plan,
# and forgetting them leaves the place reading as unknown in
# team_planning_capacity. team_planning_clear_change drops it, by the facet
# `capacity:<place id>`. Pinning one to a parent is refused for now. A place
# the person no longer holds is flagged in team_planning_attention rather than
# refused, as a later step may move them.
class Operations::TeamPlanning::SetCapacityOverride < Operations::Base
  include Operations::TeamPlanning::ChangeWrite

  KIND = ::TeamPlanning::Events::CapacitySet

  description "Override a person's capacity in one place they hold, a position or a unit, in a scenario of a Team " \
              "Planning plan. team_planning_capacity then prices the place at this amount, in the units of the " \
              "place's capacity model, with the model's figure behind it as `calculated`. Steps after the scenario, " \
              "and its alternatives, inherit the override unless they set it again. The plan keeps the amount " \
              "private to that person, so once they are forgotten the place counts nowhere. Clear it with " \
              "team_planning_clear_change and the facet `capacity:<position or unit id>`. Refused unless the " \
              "caller is one of the plan's editors."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "The scenario, or the plan's id for the baseline." }
  parameter :person_id, String, required: true, schema: { description: "A person, or a placeholder hire's id." }
  parameter :position_id, String, schema: { description: "The position the override is for. Give this or unit_id, not both." }
  parameter :unit_id, String, schema: { description: "The unit, for a place in no position." }
  parameter :amount, String, required: true, allow_blank: false,
                             schema: { description: "What the person delivers there, 0 or more, as a decimal such as \"0.8\".",
                                       pattern: "^\\d+(\\.\\d+)?$" }
  requires_any_of :position_id, :unit_id

  # @return [Hash] `{ plan_id, scenario_id, person_id, position_id, unit_id, amount }`
  def perform
    person_id = uuid!(:person_id)
    places = KIND::PLACES.index_with { params[it].presence && uuid!(it) }
    stored = nil
    set_change!(KIND, subject_id: person_id, end_state: { **places, amount: params[:amount] }) do |plan|
      stored = KIND.end_state(**places, amount: params[:amount])
      raise Operations::Base::ParameterError, "No such person" unless known?(plan, person_id)
    end

    { plan_id: plan_id!, scenario_id: scenario_id!(:scenario_id), person_id:, **stored }
  end

  private

  def known?(plan, person_id)
    ::Person.exists?(tenant_id: ActsAsTenant.current_tenant&.id, id: person_id) ||
      winning_change(plan, person_id, ::TeamPlanning::Events::PlaceholderSet.facet).present?
  end
end
