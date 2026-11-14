# frozen_string_literal: true

class AddNotedEventIdToTeamPlanningHistoryEntries < ActiveRecord::Migration[8.1]
  def change
    add_column :team_planning_history_entries, :noted_event_id, :uuid
  end
end
