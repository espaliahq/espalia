# frozen_string_literal: true

class AddSettlesToTeamPlanningHistoryEntries < ActiveRecord::Migration[8.1]
  def change
    add_column :team_planning_history_entries, :settles, :jsonb
  end
end
