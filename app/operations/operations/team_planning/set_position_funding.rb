# frozen_string_literal: true

# Says which budget lines an open position draws on, as a PositionFundingSet
# change ([#345](https://github.com/espaliahq/espalia/issues/345)), in place of
# the line team_planning_funding derives. The exception only: a position paid
# from another cost centre, or split across lines.
class Operations::TeamPlanning::SetPositionFunding < Operations::Base
  include Operations::TeamPlanning::BudgetLineWrite

  KIND = ::TeamPlanning::Events::PositionFundingSet

  DRAWS_SCHEMA = {
    type: "array", minItems: 1, maxItems: KIND::MAX_DRAWS,
    description: "The lines it draws on, each named once. A lone draw may leave out its share; otherwise the shares " \
                 "add up to 1.",
    items: {
      type: "object", additionalProperties: false, required: [ "budget_line_id" ],
      properties: {
        budget_line_id: { type: "string", description: "A line from team_planning_budget_lines." },
        share: { type: "string", pattern: "^#{KIND::SHARE.source.delete_prefix("\\A").delete_suffix("\\z")}$",
                 description: "The part of the position it funds, a decimal above 0 and at most 1, such as \"0.5\"." }
      }
    }
  }.freeze

  description "Set which budget lines an open position in a scenario of a Team Planning plan draws on, in place of " \
              "the line team_planning_funding derives: for a position paid from another cost centre, or split across " \
              "lines. Each draw names a budget_line_id the scenario holds and its share. The scenarios that follow " \
              "inherit it. team_planning_clear_change with the position_id and the facet 'funding' goes back to the " \
              "derived line. Refused on the baseline, which has no period to fund, for a position that isn't open in " \
              "the scenario, for a line the plan doesn't hold, and unless the caller is one of the plan's editors."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "The scenario. The baseline is refused." }
  parameter :position_id, String, required: true, allow_blank: false
  parameter :draws, Array, required: true, schema: DRAWS_SCHEMA

  # @return [Hash] `{ plan_id, scenario_id, position_id, draws }`
  def perform
    scenario_id = scenario!
    position_id = uuid!(:position_id)
    end_state = refusing_bad_plans { KIND.end_state(draws: params[:draws]) }
    set_change!(KIND, subject_id: position_id, end_state:) do |plan|
      open!(plan, position_id)
      end_state[:draws].each { drawable!(plan, it[:budget_line_id]) }
    end

    { plan_id: plan_id!, scenario_id:, position_id:, draws: end_state[:draws] }
  end

  private

  def open!(plan, position_id)
    return if winning_change(plan, position_id, ::TeamPlanning::Events::PositionSet.facet).is_a?(::TeamPlanning::Events::PositionSet)

    raise Operations::Base::ParameterError, "This scenario has no such open position"
  end

  def drawable!(plan, line_id)
    held!(plan, line_id)
    return unless winning_change(plan, line_id, FACET).is_a?(::TeamPlanning::Events::BudgetLineCut)

    raise Operations::Base::ParameterError, "This scenario has cut that budget line"
  end
end
