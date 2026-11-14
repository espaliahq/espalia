# frozen_string_literal: true

# Each live plan, projected from the plan streams by
# TeamPlanning::Projections::Plans. A deleted plan has no row.
class CreateTeamPlanningPlans < ActiveRecord::Migration[8.1]
  def change
    create_table :team_planning_plans, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: false
      t.string :name, null: false
      t.date :base_on, null: false
      t.uuid :created_by_id, null: false
      t.timestamps
    end
    add_index :team_planning_plans, %i[tenant_id created_by_id]
  end
end
