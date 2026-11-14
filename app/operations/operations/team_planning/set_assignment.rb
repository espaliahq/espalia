# frozen_string_literal: true

# Sets every place a person holds in a scenario, as an AssignmentSet change.
# The person and position checks run under the plan's lock, after the editor
# check, so an outsider gets "No such plan" and learns nothing about who
# works here. A total over 1 is read by the checks, never refused
# [#229](https://github.com/espaliahq/espalia/issues/229).
class Operations::TeamPlanning::SetAssignment < Operations::Base
  include Operations::TeamPlanning::ChangeWrite

  ASSIGNMENT = ::TeamPlanning::Events::AssignmentSet

  PLACEMENTS_SCHEMA = {
    type: "array",
    description: "Every place the person holds, or none to leave them unassigned.",
    items: {
      type: "object",
      additionalProperties: false,
      properties: {
        position_id: { type: "string", description: "A position the scenario has. Give this or unit_id, not both." },
        unit_id: { type: "string", description: "A unit, for a place in no position." },
        allocation: { type: "number", exclusiveMinimum: 0, maximum: 1 },
        role: { type: "string", description: "The person's role in the place, such as Lead." }
      },
      required: %w[allocation],
      oneOf: [ { required: %w[position_id] }, { required: %w[unit_id] } ]
    }
  }.freeze

  description "Set every place a person holds in a scenario of a Team Planning plan: each a position or a unit, " \
              "with an allocation above 0 and at most 1 and an optional role. The person's places become exactly " \
              "this list, and an empty list leaves them unassigned. A place in a position follows the position " \
              "if it moves. Allocations may total over 1; the scenario map shows the total. Steps after the " \
              "scenario, and its alternatives, inherit the list unless they set it again. Refused unless the " \
              "caller is one of the plan's editors."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "The scenario, or the plan's id for the baseline." }
  parameter :person_id, String, required: true
  parameter :placements, Array, required: true, schema: PLACEMENTS_SCHEMA

  # @return [Hash] `{ plan_id, scenario_id, person_id, placements, allocation_total }`
  def perform
    person_id = uuid!(:person_id)
    end_state = refusing_bad_plans { ASSIGNMENT.end_state(placements: params[:placements]) }
    set_change!(ASSIGNMENT, subject_id: person_id, end_state:) do |plan|
      raise Operations::Base::ParameterError, "No such person" unless ::Person.exists?(tenant_id: ActsAsTenant.current_tenant&.id, id: person_id)

      end_state[:placements].filter_map { it[:position_id] }.each { known_position!(plan, it) }
    end

    { plan_id: plan_id!, scenario_id: scenario_id!(:scenario_id), person_id:, **end_state,
      allocation_total: end_state[:placements].sum { it[:allocation] }.round(4) }
  end

  private

  def known_position!(plan, position_id)
    return if winning_change(plan, position_id, ::TeamPlanning::Events::PositionSet.facet)

    raise Operations::Base::ParameterError, "This scenario has no such position"
  end
end
