# frozen_string_literal: true

class AddArchivedToTeamPlanningPlans < ActiveRecord::Migration[8.1]
  def change
    add_column :team_planning_plans, :archived_on, :date
    add_column :team_planning_plans, :archived_by_id, :uuid
  end
end
