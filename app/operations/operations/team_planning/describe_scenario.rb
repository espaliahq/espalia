# frozen_string_literal: true

# Says what a scenario is for. The description is sealed under the plan's key,
# so deleting the plan forgets it.
#
# The plan never sees a description once written, so this tells it what the
# scenarios read model holds and the same text writes nothing. That model is
# written in the same transaction as each event, so it is current unless a
# rebuild holds it; then this writes rather than guess.
class Operations::TeamPlanning::DescribeScenario < Operations::Base
  include Operations::TeamPlanning::PlanWrite

  description "Say what a scenario in a Team Planning plan is for, such as 'Hire two seniors before Q3'. " \
              "A blank description clears it. Deleting the plan forgets it. Refused for the baseline, or unless " \
              "the caller is one of its editors."
  category :write
  approval :mcp_client
  prose_fields :description

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true
  parameter :description, String, required: true

  # @return [Hash] `{ plan_id, scenario_id, description }`
  def perform
    plan_id = plan_id!
    scenario_id = scenario_id!(:scenario_id)
    refusing_bad_plans do
      handler.describe_scenario(plan_id, scenario_id, description: params[:description], current: -> { current(scenario_id) })
    end
    { plan_id:, scenario_id:, description: params[:description].to_s.strip.presence }
  end

  private

  def current(scenario_id)
    row = ProjectionVersion.unless_rebuilding(::TeamPlanning::Projections::Scenarios::PROJECTION_NAME) do
      TeamPlanningScenario.find_by(id: scenario_id)
    end
    row ? row.description&.reveal : ::TeamPlanning::PlanAggregate::UNKNOWN
  rescue ProjectionVersion::Rebuilding
    ::TeamPlanning::PlanAggregate::UNKNOWN
  end
end
