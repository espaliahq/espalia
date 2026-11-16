# frozen_string_literal: true

# Opens, edits, closes and moves positions from the scenario map ([#285](https://github.com/espaliahq/espalia/issues/285),
# [#461](https://github.com/espaliahq/espalia/issues/461)), through the same
# Operations as the `team_planning_set_position`, `_edit_position`,
# `_close_position` and `_move_position` tools. A plan someone isn't in is a
# 404, as on the plan's page; a viewer is refused, and so is Today.
#
# An edit sends only the fields that differ from `original[…]`, the values
# the dialog opened with, so it keeps a change another editor made meanwhile.
# A refused open or edit renders the form again in its dialog, with what was
# typed.
class Plans::PositionsController < ApplicationController
  include Plans::MapEditing

  TODAY = "Today can't be edited. Fork a scenario and edit that."
  PERMITTED = %i[scenario_id unit_id level_id fte basis cost_centre].freeze
  NOTICES = { open: "Position opened.", edit: "Position saved." }.freeze

  # POST /planning/:plan_id/positions
  def create
    authorize_editor
    write(:open) do
      Operations::TeamPlanning::SetPosition.call(context: pundit_user, params: { plan_id:, scenario_id:, **fields(typed) })
    end
  end

  # PATCH /planning/:plan_id/positions/:id
  def update
    authorize_editor
    write(:edit) do
      edits = fields(changed)
      next :unchanged if edits.empty?

      Operations::TeamPlanning::EditPosition.call(context: pundit_user, params: { plan_id:, scenario_id:, position_id: params.expect(:id), **edits })
    end
  end

  # DELETE /planning/:plan_id/positions/:id
  def destroy
    authorize_editor
    scenario = params.expect(:scenario_id)
    refuse_today!(scenario)
    Operations::TeamPlanning::ClosePosition.call(context: pundit_user, params: { plan_id:, scenario_id: scenario, position_id: params.expect(:id) })
    redirect_to map_plan_path(plan_id, scenario:), notice: "Position closed.", status: :see_other
  rescue Operations::Base::ParameterError => e
    redirect_back_or_to map_plan_path(plan_id), alert: "Couldn't close the position: #{e.message}", status: :see_other
  end

  # PATCH /planning/:plan_id/positions/:id/move
  def move
    authorize_editor
    Operations::TeamPlanning::MovePosition.call(context: pundit_user, params: { plan_id:, position_id: params.expect(:id), **move_params })
    redirect_to map_plan_path(plan_id, scenario: move_params[:scenario_id]), notice: "Position moved."
  rescue Operations::Base::ParameterError => e
    redirect_back_or_to map_plan_path(plan_id), alert: "Couldn't move the position: #{e.message}"
  end

  private

  def write(mode)
    refuse_today!(scenario_id)
    notice = yield == :unchanged ? "Nothing changed." : NOTICES.fetch(mode)
    redirect_to map_plan_path(plan_id, scenario: scenario_id), notice:, status: :see_other
  rescue Operations::Base::ParameterError, TeamPlanning::Error => e
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(Views::Plans::PositionForm.dom_id_for(mode), refused_form(mode, e.message)),
               status: :unprocessable_content
      end
      format.html { redirect_back_or_to map_plan_path(plan_id), alert: "Couldn't save the position: #{e.message}", status: :see_other }
    end
  end

  def refuse_today!(scenario)
    raise Operations::Base::ParameterError, TODAY if scenario == plan_id
  end

  def scenario_id = typed.fetch(:scenario_id) { raise ActionController::ParameterMissing, :scenario_id }

  def typed = @typed ||= params.expect(position: PERMITTED).to_h.symbolize_keys

  def original = params.fetch(:original, {}).permit(*Views::Plans::PositionForm::FIELDS).to_h.symbolize_keys

  def changed = typed.reject { |field, value| field == :scenario_id || (original.key?(field) && same?(field, original[field], value)) }

  # "1" and "1.0" are one FTE: a spinner nudged and put back is no edit.
  def same?(field, was, now)
    return was == now unless field == :fte

    Float(was) == Float(now)
  rescue ArgumentError, TypeError
    was == now
  end

  # The form names a level, which belongs to one role, so the role comes
  # with it. A blank or non-numeric FTE is refused rather than read as 0.
  def fields(given)
    given = given.except(:scenario_id)
    if given.key?(:level_id)
      level = FrameworkState::Level.find_by(level_id: given[:level_id].presence) or
        raise Operations::Base::ParameterError, "Choose a role and level"
      given = given.merge(role_id: level.role_id)
    end
    given = given.merge(fte: fte!(given[:fte])) if given.key?(:fte)
    given
  end

  def fte!(value)
    Float(value.to_s.strip)
  rescue ArgumentError
    raise Operations::Base::ParameterError, "Give the FTE as a number above 0 and at most 1"
  end

  def refused_form(mode, error)
    map = Operations::TeamPlanning::ScenarioMap.call(context: pundit_user, params: { plan_id:, scenario_id: })
    scenario = Operations::TeamPlanning::Scenarios.call(context: pundit_user, params: { plan_id: })[:scenarios].find { it[:scenario_id] == scenario_id }
    Views::Plans::PositionForm.new(
      mode:, scenario_id:, scenario_name: scenario&.dig(:name) || "this scenario", units: Views::Plans::ScenarioMap.ordered_units(map[:units]),
      roles: FrameworkState::Role.includes(:levels).order(:name).to_a, action: request.path, values: typed, original:,
      name: refused_name(mode, map), error:
    )
  end

  def refused_name(mode, map)
    if mode == :edit
      position = map[:positions].find { it[:position_id] == params[:id] }
      position ? Views::Plans::ScenarioMap.position_label(position) : "this position"
    else
      map[:units].find { it[:id] == typed[:unit_id] }&.dig(:name) || "this unit"
    end
  end

  def move_params = @move_params ||= params.expect(move: [ :scenario_id, :to_unit_id ]).to_h.symbolize_keys
end
