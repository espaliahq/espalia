# frozen_string_literal: true

class CreateTenants < ActiveRecord::Migration[8.1]
  def change
    create_table :tenants, id: :uuid, default: nil do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.jsonb :settings, null: false, default: {}

      t.timestamps
    end

    add_index :tenants, :slug, unique: true
  end
end
