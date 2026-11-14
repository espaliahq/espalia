# frozen_string_literal: true

class AddNotesToTeamPlanningReadModels < ActiveRecord::Migration[8.1]
  def change
    add_column :team_planning_overrides, :note, :jsonb
    add_column :team_planning_history_entries, :note, :jsonb
    add_column :team_planning_history_entries, :noted_event_id, :uuid
  end
end
