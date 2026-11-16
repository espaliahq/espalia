# frozen_string_literal: true

# Clears or undoes a planned change from the Changes tab, through the same
# Operations the MCP tools use. The tab offers it on a change about someone
# the plan no longer covers, where nothing else is left to do
# ([#435](https://github.com/espaliahq/espalia/issues/435)). Both act in the
# scenario that made the change, since a child that only inherits it has
# nothing to clear.
class Plans::ChangeReversalsController < ApplicationController
  include Plans::MapEditing

  NOTICES = { "clear" => "Change cleared.", "undo" => "Change undone." }.freeze

  # POST /planning/:plan_id/change-reversals
  def create
    authorize_editor
    fields = params.expect(reversal: [ :scenario_id, :subject_id, :facet, :change_id, :choice ])
    reverse(fields)
    redirect_to back_to_tab, notice: NOTICES.fetch(fields[:choice])
  rescue Operations::Base::ParameterError => e
    redirect_to back_to_tab, alert: "Couldn't #{fields&.dig(:choice) == 'undo' ? 'undo' : 'clear'} the change: #{e.message}"
  end

  private

  def reverse(fields)
    scope = { plan_id:, scenario_id: fields[:scenario_id] }
    case fields[:choice]
    when "clear" then Operations::TeamPlanning::ClearChange.call(context: pundit_user, params: { **scope, subject_id: fields[:subject_id], facet: fields[:facet] })
    when "undo" then Operations::TeamPlanning::UndoChange.call(context: pundit_user, params: { **scope, event_id: fields[:change_id] })
    else raise Operations::Base::ParameterError, "Choose clear or undo"
    end
  end

  # The scenario shown, which may only inherit the change.
  def back_to_tab = changes_plan_path(plan_id, scenario: params[:shown].presence)
end
