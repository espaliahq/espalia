# frozen_string_literal: true

class CreateTeamPlanningRemovedScenarios < ActiveRecord::Migration[8.1]
  def change
    create_table :team_planning_removed_scenarios, id: :uuid, default: nil do |t|
      t.uuid :tenant_id, null: false
      t.uuid :plan_id, null: false
      t.jsonb :name
      t.string :relation
      t.date :starts_on
      t.date :ends_on
      t.uuid :removed_by_id
      t.datetime :removed_at, null: false
      t.timestamps
    end
    add_index :team_planning_removed_scenarios, [ :tenant_id, :plan_id ]
  end
end
