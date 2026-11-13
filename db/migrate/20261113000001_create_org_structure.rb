# frozen_string_literal: true

# The current unit tree and taxonomy, projected from each tenant's
# OrgStructure stream. Both primary keys are event-carried ids, so they
# survive a rebuild.
class CreateOrgStructure < ActiveRecord::Migration[8.1]
  def change
    create_table :org_taxonomy_levels, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: false
      t.string :name, null: false
      t.integer :position, null: false
      t.date :effective_on, null: false
      t.timestamps
    end
    add_index :org_taxonomy_levels, %i[tenant_id position], unique: true

    create_table :org_units, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: false
      t.string :name, null: false
      t.date :name_effective_on, null: false
      t.uuid :parent_id
      t.date :parent_effective_on, null: false
      t.uuid :level_id, null: false
      t.string :provider, null: false
      t.string :external_ref
      t.date :created_on, null: false
      t.date :retired_on
      t.timestamps
    end
    add_index :org_units, %i[tenant_id parent_id]
    add_index :org_units, %i[tenant_id provider external_ref], unique: true,
              where: "external_ref IS NOT NULL AND retired_on IS NULL",
              name: "index_org_units_on_live_external_ref"
  end
end
