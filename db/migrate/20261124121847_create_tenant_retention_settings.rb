# frozen_string_literal: true

class CreateTenantRetentionSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :tenant_retention_settings, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: { unique: true }
      t.integer :retention_years
      t.boolean :scheduled_forgetting, null: false, default: false
      t.datetime :enabled_at
      t.uuid :enabled_by_id
      t.timestamps
    end
  end
end
