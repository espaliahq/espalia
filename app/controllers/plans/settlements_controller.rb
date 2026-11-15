# frozen_string_literal: true

# Settles a conflict an update to today carried forward, from the Changes tab
# ([#336](https://github.com/espaliahq/espalia/issues/336)), through the same
# Operation the MCP tool uses. It settles in the scenario shown alone, so the
# scenario that made the change and its other children keep it.
class Plans::SettlementsController < ApplicationController
  include Plans::MapEditing

  NOTICES = { "plan" => "Kept the plan.", "reality" => "Following reality." }.freeze

  # POST /planning/:plan_id/settlements
  def create
    authorize_editor
    fields = params.expect(settlement: [ :scenario_id, :subject_id, :facet, :choice ])
    Operations::TeamPlanning::SettleConflict.call(context: pundit_user, params: { plan_id:, **fields.to_h.symbolize_keys })
    redirect_to back_to_tab(fields[:scenario_id]), notice: NOTICES.fetch(fields[:choice])
  rescue Operations::Base::ParameterError => e
    redirect_to back_to_tab(fields&.dig(:scenario_id)), alert: "Couldn't settle the conflict: #{e.message}"
  end

  private

  def back_to_tab(scenario_id) = changes_plan_path(plan_id, scenario: (scenario_id unless scenario_id == plan_id).presence)
end
