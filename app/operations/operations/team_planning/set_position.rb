# frozen_string_literal: true

# Opens a position in a scenario, or changes or reopens one, as a
# PositionSet change. The role, level and position checks run under the
# plan's lock, after the editor check, so an outsider gets "No such plan"
# and learns nothing about the framework
# [#228](https://github.com/espaliahq/espalia/issues/228).
class Operations::TeamPlanning::SetPosition < Operations::Base
  include Operations::TeamPlanning::ChangeWrite

  POSITION = ::TeamPlanning::Events::PositionSet

  description "Open a position in a scenario of a Team Planning plan, or change or reopen one by passing its " \
              "position_id. A position is a framework role and one of that role's levels (the level pay bands " \
              "key on), in a unit, at an FTE above 0 and at most 1. basis 'backfill' is committed budget; 'new' " \
              "is planned. cost_centre is the position's own label, which decides its open seat and any occupant the plan " \
              "changes, ahead of the cost_centre rules; an occupant the plan leaves alone keeps their own. Omit it to leave " \
              "the position to the rules, which clears any label it had. Give every field each time: the scenario's position becomes exactly this. Steps after " \
              "the scenario, and its alternatives, inherit it unless they change it. Refused unless the caller " \
              "is one of the plan's editors."
  category :write
  approval :mcp_client

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "The scenario, or the plan's id for the baseline." }
  parameter :position_id, String, allow_blank: false, schema: { description: "Omit to open a new position." }
  parameter :role_id, String, required: true
  parameter :level_id, String, required: true
  parameter :unit_id, String, required: true
  parameter :fte, Numeric, required: true, schema: { exclusiveMinimum: 0, maximum: 1 }
  parameter :basis, String, required: true, schema: { enum: POSITION::BASES }
  parameter :cost_centre, String, schema: { maxLength: POSITION::COST_CENTRE_LENGTH }

  # @return [Hash] `{ plan_id, scenario_id, position_id, role_id, level_id, unit_id, fte, basis, cost_centre, budget }`
  def perform
    position_id = params[:position_id].nil? ? SecureRandom.uuid_v7 : uuid!(:position_id)
    end_state = { role_id: uuid!(:role_id), level_id: uuid!(:level_id), unit_id: uuid!(:unit_id), fte: params[:fte], basis: params[:basis],
                  cost_centre: params[:cost_centre] }
    set_change!(POSITION, subject_id: position_id, end_state:) do |plan|
      known_position!(plan, position_id) unless params[:position_id].nil?
      role_and_level!(end_state)
    end

    stored = POSITION.end_state(end_state)
    { plan_id: plan_id!, scenario_id: scenario_id!(:scenario_id), position_id:, **stored,
      budget: ::TeamPlanning::Baseline::Position.budget_of(stored[:basis]) }
  end

  private

  def known_position!(plan, position_id)
    return if winning_change(plan, position_id, POSITION.facet)

    raise Operations::Base::ParameterError, "This scenario has no such position"
  end

  def role_and_level!(end_state)
    level = FrameworkState::Level.find_by(level_id: end_state[:level_id])
    raise Operations::Base::ParameterError, "No such role" unless FrameworkState::Role.exists?(role_id: end_state[:role_id])
    raise Operations::Base::ParameterError, "No such level" unless level
    raise Operations::Base::ParameterError, "That level belongs to another role" unless level.role_id == end_state[:role_id]
  end
end
