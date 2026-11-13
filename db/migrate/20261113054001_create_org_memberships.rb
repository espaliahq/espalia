# frozen_string_literal: true

# Each unit's current members, projected from the person streams.
class CreateOrgMemberships < ActiveRecord::Migration[8.1]
  def change
    create_table :org_memberships, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: false
      t.uuid :unit_id, null: false
      t.uuid :person_id, null: false
      t.float :allocation
      t.string :role
      t.string :provider, null: false
      t.date :member_since, null: false
      t.date :effective_on, null: false
      t.timestamps
    end
    add_index :org_memberships, %i[tenant_id unit_id person_id], unique: true
    add_index :org_memberships, %i[tenant_id person_id]
  end
end
