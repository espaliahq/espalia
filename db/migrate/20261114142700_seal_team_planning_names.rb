# frozen_string_literal: true

# Plan and scenario names become shreddable, so their columns hold the
# sealed form. Each name reads as removed until the rebuild that ships with
# this release seals it from the events (REBUILD_ON_DEPLOY). A baseline's
# name is the app's own, so its row holds none.
class SealTeamPlanningNames < ActiveRecord::Migration[8.1]
  def up
    %i[team_planning_plans team_planning_scenarios].each do |table|
      change_column table, :name, :jsonb, null: false, using: %q('{"removed": true}'::jsonb)
    end
    change_column_null :team_planning_scenarios, :name, true
  end

  def down
    %i[team_planning_plans team_planning_scenarios].each do |table|
      change_column table, :name, :string, null: false, using: "''"
    end
  end
end
