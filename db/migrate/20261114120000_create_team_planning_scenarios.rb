# frozen_string_literal: true

# Each live plan's scenarios, the baseline among them, projected from the plan
# streams by TeamPlanning::Projections::Scenarios.
class CreateTeamPlanningScenarios < ActiveRecord::Migration[8.1]
  def change
    create_table :team_planning_scenarios, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: false
      t.uuid :plan_id, null: false
      t.uuid :parent_id
      t.string :relation
      t.string :name, null: false
      t.date :starts_on, null: false
      t.date :ends_on
      t.uuid :forked_by_id
      t.timestamps
    end
    add_index :team_planning_scenarios, %i[tenant_id plan_id]
  end
end
