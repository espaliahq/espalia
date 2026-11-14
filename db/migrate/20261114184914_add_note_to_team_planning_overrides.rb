# frozen_string_literal: true

class AddNoteToTeamPlanningOverrides < ActiveRecord::Migration[8.1]
  def change
    add_column :team_planning_overrides, :note, :jsonb
  end
end
