# frozen_string_literal: true

# A unit's stated owners, projected from the tenant's OrgStructure stream.
# owners_lost_on marks a unit whose last owner was removed, until one is named.
class CreateOrgUnitOwners < ActiveRecord::Migration[8.1]
  def change
    create_table :org_unit_owners, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: false
      t.uuid :unit_id, null: false
      t.uuid :person_id, null: false
      t.date :owner_since, null: false
      t.timestamps
    end
    add_index :org_unit_owners, %i[tenant_id unit_id person_id], unique: true
    add_index :org_unit_owners, %i[tenant_id person_id]

    add_column :org_units, :owners_lost_on, :date
  end
end
