# frozen_string_literal: true

# The plan change an activity entry's event was applied from, and the cause the
# feed groups entries by, so a group can name its plan change and be found by
# its cause.
class AddPlanReferenceToOrgUnitActivities < ActiveRecord::Migration[8.1]
  def change
    add_column :org_unit_activities, :plan_id, :string
    add_column :org_unit_activities, :plan_change_id, :string
    add_column :org_unit_activities, :cause_id, :string
    add_index :org_unit_activities, %i[tenant_id cause_id]
    add_index :org_unit_activities, %i[tenant_id unit_id cause_id]
  end
end
