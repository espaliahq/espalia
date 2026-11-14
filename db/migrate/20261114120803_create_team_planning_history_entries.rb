# frozen_string_literal: true

class CreateTeamPlanningHistoryEntries < ActiveRecord::Migration[8.1]
  def change
    # The id is the event id, so a rebuild keeps it.
    create_table :team_planning_history_entries, id: :uuid, default: nil do |t|
      t.uuid :tenant_id, null: false
      t.uuid :plan_id, null: false
      t.uuid :scenario_id, null: false
      t.integer :position, null: false
      t.string :action, null: false
      t.string :subject_id
      t.string :facet
      t.string :kind
      t.jsonb :end_state
      t.string :sealed_fields, array: true, null: false, default: []
      t.uuid :pinned_from_scenario_id
      t.uuid :pinned_from_event_id
      t.uuid :reverses_event_id
      t.uuid :actor_id
      t.datetime :at, null: false
      t.uuid :undone_by_id
      t.datetime :undone_at
      t.timestamps
    end
    add_index :team_planning_history_entries, %i[tenant_id plan_id]
    add_index :team_planning_history_entries, %i[scenario_id position], unique: true
  end
end
