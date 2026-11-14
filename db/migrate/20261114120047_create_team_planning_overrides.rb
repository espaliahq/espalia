# frozen_string_literal: true

class CreateTeamPlanningOverrides < ActiveRecord::Migration[8.1]
  def change
    create_table :team_planning_overrides, id: :uuid, default: nil do |t|
      t.uuid :tenant_id, null: false
      t.uuid :plan_id, null: false
      t.uuid :scenario_id, null: false
      t.string :subject_id, null: false
      t.string :facet, null: false
      t.string :kind, null: false
      t.jsonb :end_state, null: false, default: {}
      t.boolean :pinned, null: false, default: false
      t.uuid :pinned_from_scenario_id
      t.uuid :pinned_from_event_id
      t.uuid :event_id, null: false
      t.uuid :set_by_id
      t.datetime :set_at, null: false
      t.timestamps
    end
    add_index :team_planning_overrides, %i[tenant_id plan_id scenario_id]
    add_index :team_planning_overrides, %i[scenario_id subject_id facet], unique: true
  end
end
