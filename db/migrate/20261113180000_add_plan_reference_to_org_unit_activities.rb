# frozen_string_literal: true

# The plan change an activity entry's event was applied from, so the feed can
# name it beside a group of changes.
class AddPlanReferenceToOrgUnitActivities < ActiveRecord::Migration[8.1]
  def change
    add_column :org_unit_activities, :plan_id, :string
    add_column :org_unit_activities, :plan_change_id, :string
  end
end
