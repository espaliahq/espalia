# frozen_string_literal: true

class CreateTeamPlanningRemovedScenarioTallies < ActiveRecord::Migration[8.1]
  def change
    create_table :team_planning_removed_scenario_tallies, id: :uuid, default: nil do |t|
      t.uuid :tenant_id, null: false
      t.uuid :plan_id, null: false
      t.integer :changes_held, null: false
      t.timestamps
    end
    add_index :team_planning_removed_scenario_tallies, [ :tenant_id, :plan_id ]
  end
end
