# frozen_string_literal: true

class CreatePayBands < ActiveRecord::Migration[8.1]
  def change
    create_table :pay_bands, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: false
      t.uuid :level_id, null: false
      t.string :role_name, null: false
      t.string :level_name, null: false
      t.string :location, null: false, default: ""
      t.string :location_key, null: false, default: ""
      t.string :currency, null: false
      t.string :period, null: false
      t.decimal :minimum, precision: 14, scale: 2, null: false
      t.decimal :midpoint, precision: 14, scale: 2, null: false
      t.decimal :maximum, precision: 14, scale: 2, null: false
      t.references :updated_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
    end

    add_index :pay_bands, %i[tenant_id level_id location_key], unique: true
    add_check_constraint :pay_bands, "minimum <= midpoint AND midpoint <= maximum", name: "pay_bands_ordered"
    add_check_constraint :pay_bands, "minimum >= 0", name: "pay_bands_not_negative"
  end
end
