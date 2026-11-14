# frozen_string_literal: true

# Who is in each live plan, and as what, projected from the plan streams by
# TeamPlanning::Projections::PlanMembers.
class CreateTeamPlanningPlanMembers < ActiveRecord::Migration[8.1]
  def change
    create_table :team_planning_plan_members, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: false
      t.uuid :plan_id, null: false
      t.uuid :person_id, null: false
      t.string :role, null: false
      t.timestamps
    end
    add_index :team_planning_plan_members, %i[plan_id person_id], unique: true
    add_index :team_planning_plan_members, %i[tenant_id person_id]
  end
end
