# frozen_string_literal: true

# Sends Undo, Redo and Clear back to the tab and scenario they were pressed on
# ([#424](https://github.com/espaliahq/espalia/issues/424)), so the map, the
# Changes tab and the cost strip all read the plan as it now stands.
module Plans::TabReturn
  extend ActiveSupport::Concern

  TABS = { "map" => :map_plan_path, "changes" => :changes_plan_path, "checks" => :checks_plan_path, "budget" => :budget_plan_path }.freeze

  private

  def scenario_id = params.expect(:scenario_id).to_s.downcase

  # An unknown tab goes to the map rather than to an address the form named.
  def back_to_tab = send(TABS.fetch(params[:tab].to_s, :map_plan_path), plan_id, scenario: scenario_id)
end
