# frozen_string_literal: true

# One row per link a stated succession makes between a predecessor and a
# successor, projected from each tenant's OrgStructure stream.
class CreateOrgUnitSuccessions < ActiveRecord::Migration[8.1]
  def change
    create_table :org_unit_successions, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: false
      t.uuid :succession_id, null: false
      t.uuid :predecessor_id, null: false
      t.uuid :successor_id, null: false
      t.date :effective_on, null: false
      t.timestamps
    end
    add_index :org_unit_successions, %i[tenant_id succession_id predecessor_id successor_id], unique: true,
              name: "index_org_unit_successions_on_link"
    add_index :org_unit_successions, %i[tenant_id predecessor_id]
    add_index :org_unit_successions, %i[tenant_id successor_id]
  end
end
