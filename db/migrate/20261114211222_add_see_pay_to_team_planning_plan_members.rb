# frozen_string_literal: true

class AddSeePayToTeamPlanningPlanMembers < ActiveRecord::Migration[8.1]
  def change
    change_table :team_planning_plan_members, bulk: true do |t|
      t.boolean :see_pay, null: false, default: false
      t.uuid :see_pay_granted_by_id
      t.datetime :see_pay_granted_at
      t.boolean :see_pay_by_recovery, null: false, default: false
    end
  end
end
