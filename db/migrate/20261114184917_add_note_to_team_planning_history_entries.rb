# frozen_string_literal: true

class AddNoteToTeamPlanningHistoryEntries < ActiveRecord::Migration[8.1]
  def change
    add_column :team_planning_history_entries, :note, :jsonb
  end
end
