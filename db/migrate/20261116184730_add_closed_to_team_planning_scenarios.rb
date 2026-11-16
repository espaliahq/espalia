# frozen_string_literal: true

class AddClosedToTeamPlanningScenarios < ActiveRecord::Migration[8.1]
  def change
    add_column :team_planning_scenarios, :closed_on, :date
    add_column :team_planning_scenarios, :closed_by_id, :uuid
  end
end
