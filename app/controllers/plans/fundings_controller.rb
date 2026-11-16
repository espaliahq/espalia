# frozen_string_literal: true

# Sets which budget lines a position draws on from the Budget tab, or hands it
# back to the line the plan derives ([#411](https://github.com/espaliahq/espalia/issues/411)),
# through `team_planning_set_position_funding` and `team_planning_clear_change`.
# The form takes each line's part as a percentage; the operation takes a share.
class Plans::FundingsController < ApplicationController
  include Plans::MapEditing

  # PATCH /planning/:plan_id/fundings/:id
  def update
    authorize_editor
    Operations::TeamPlanning::SetPositionFunding.call(context: pundit_user, params: { plan_id:, scenario_id:, position_id: params.expect(:id), draws: })
    redirect_to back_path, notice: "Funding set.", status: :see_other
  rescue Operations::Base::ParameterError => e
    redirect_to back_path, alert: "Couldn't set the funding: #{e.message}", status: :see_other
  end

  # DELETE /planning/:plan_id/fundings/:id
  def destroy
    authorize_editor
    Operations::TeamPlanning::ClearChange.call(context: pundit_user, params: { plan_id:, scenario_id:, subject_id: params.expect(:id), facet: "funding" })
    redirect_to back_path, notice: "Funding goes back to the line the plan finds.", status: :see_other
  rescue Operations::Base::ParameterError => e
    redirect_to back_path, alert: "Couldn't clear the funding: #{e.message}", status: :see_other
  end

  private

  def scenario_id = params.expect(:scenario_id).to_s.downcase

  def back_path = budget_plan_path(plan_id, scenario: scenario_id)

  # A line left blank or at 0 isn't drawn on. A lone line takes the whole
  # position. The checks speak in percentages here so the operation's, which
  # speak in shares, never reach the form.
  #
  # @raise [Operations::Base::ParameterError] for a part that isn't a percentage, or parts that don't add up to 100
  def draws
    parts = params.fetch(:funding, {}).permit(parts: {}).fetch(:parts, {}).to_h.transform_values { it.to_s.strip.delete_suffix("%") }
    chosen = parts.reject { |_, part| part.blank? || part.match?(/\A0+(\.0+)?\z/) }.transform_values { percent(it) }
    raise Operations::Base::ParameterError, "Give at least one line a part" if chosen.empty?
    return [ { budget_line_id: chosen.keys.sole } ] if chosen.one?
    raise Operations::Base::ParameterError, "The parts add up to 100" unless chosen.values.sum == 100

    chosen.map { |budget_line_id, part| { budget_line_id:, share: (part / 100).to_s("F") } }
  end

  def percent(part)
    figure = BigDecimal(part) if part.match?(/\A\d{1,3}(\.\d{1,4})?\z/)
    raise Operations::Base::ParameterError, "Each part is a percentage above 0 and at most 100, such as 50" unless figure&.between?(0.0001, 100)

    figure
  end
end
