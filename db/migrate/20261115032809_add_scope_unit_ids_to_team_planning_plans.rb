# frozen_string_literal: true

class AddScopeUnitIdsToTeamPlanningPlans < ActiveRecord::Migration[8.1]
  def change
    add_column :team_planning_plans, :scope_unit_ids, :uuid, array: true
  end
end
