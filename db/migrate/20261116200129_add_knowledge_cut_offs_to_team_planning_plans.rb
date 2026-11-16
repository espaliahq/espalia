# frozen_string_literal: true

# The instants a plan's baseline and archive stopped learning, fixed in the
# zone the tenant had when each was written, so a later zone change moves
# neither. A plan written before tenants had zones leaves them empty, and
# reads the UTC end of its day.
class AddKnowledgeCutOffsToTeamPlanningPlans < ActiveRecord::Migration[8.1]
  def change
    add_column :team_planning_plans, :base_known_at, :datetime
    add_column :team_planning_plans, :archived_known_at, :datetime
  end
end
