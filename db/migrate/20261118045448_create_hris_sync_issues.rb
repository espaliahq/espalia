# frozen_string_literal: true

class CreateHrisSyncIssues < ActiveRecord::Migration[8.1]
  def change
    create_table :hris_sync_issues, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.string :provider, null: false
      t.string :kind, null: false
      t.uuid :unit_id, null: false
      t.uuid :parent_id
      t.uuid :structure_unit_id
      t.date :first_seen_on, null: false
      t.date :last_seen_on, null: false
      t.timestamps
    end
    add_index :hris_sync_issues, %i[tenant_id kind unit_id], unique: true
  end
end
