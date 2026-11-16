# frozen_string_literal: true

# Sets every place a person holds in a scenario, as an AssignmentSet change.
# Every check runs under the plan's lock, after the editor check, so an
# outsider gets "No such plan" whatever the placements say. Fit is read,
# never refused: a place in a closed position resolves with no unit, and a
# total over 1 is left to the checks. Only a position the scenario never had
# is refused [#229](https://github.com/espaliahq/espalia/issues/229). A
# placeholder hire the scenario holds is placed like anyone else.
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
              "scenario, and its alternatives, inherit the list unless they set it again. A placeholder hire is placed by its id. Refused unless the " \
              "caller is one of the plan's editors."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "The scenario, or the plan's id for the baseline." }
  parameter :person_id, String, required: true
  parameter :placements, Array, required: true, schema: PLACEMENTS_SCHEMA

  # @return [Hash] `{ plan_id, scenario_id, person_id, placements }`
  def perform
    person_id = uuid!(:person_id)
    stored = nil
    set_change!(ASSIGNMENT, subject_id: person_id, end_state: { placements: params[:placements] }) do |plan|
      stored = ASSIGNMENT.end_state(placements: params[:placements])
      raise Operations::Base::ParameterError, "No such person" unless placeable?(plan, person_id)

      stored[:placements].each { place!(plan, it) }
    end

    { plan_id: plan_id!, scenario_id: scenario_id!(:scenario_id), person_id:, **stored }
  end

  private

  # An unknown allocation is only ever followed from the Org Graph, never set.
  def place!(plan, placement)
    raise Operations::Base::ParameterError, "An allocation is above 0 and at most 1" if placement[:allocation].nil?

    placement.slice(*ASSIGNMENT::PLACES).compact.each do |name, id|
      raise Operations::Base::ParameterError, "#{name} must be a UUID, got #{id.inspect}" unless id.match?(UUID_RE)
    end
    return unless placement[:position_id]
    return if winning_change(plan, placement[:position_id], ::TeamPlanning::Events::PositionSet.facet)

    raise Operations::Base::ParameterError, "This scenario has no such position"
  end

  def placeable?(plan, person_id)
    ::Person.exists?(tenant_id: ActsAsTenant.current_tenant&.id, id: person_id) ||
      winning_change(plan, person_id, ::TeamPlanning::Events::PlaceholderSet.facet).present?
  end
end
