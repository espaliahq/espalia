class AddDescriptionToTeamPlanningScenarios < ActiveRecord::Migration[8.1]
  def change
    add_column :team_planning_scenarios, :description, :jsonb
  end
end
