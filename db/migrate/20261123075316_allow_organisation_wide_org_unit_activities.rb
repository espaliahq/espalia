# frozen_string_literal: true

# An organisation-wide entry, such as an Org Graph editor grant, belongs to no
# unit. Postgres reads NULLs as distinct, so the existing unique index on
# (tenant_id, event_id, unit_id) can't hold these rows to one per event.
class AllowOrganisationWideOrgUnitActivities < ActiveRecord::Migration[8.1]
  def change
    change_column_null :org_unit_activities, :unit_id, true
    add_index :org_unit_activities, %i[tenant_id event_id], unique: true, where: "unit_id IS NULL",
                                                             name: "index_org_unit_activities_organisation_wide"
  end
end
