# frozen_string_literal: true

class CreateExchangeRates < ActiveRecord::Migration[8.1]
  def change
    create_table :reference_currencies, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: { unique: true }
      t.string :currency, null: false
      t.references :updated_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
    end

    create_table :exchange_rates, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: false
      t.string :from_currency, null: false
      t.string :to_currency, null: false
      t.decimal :rate, precision: 24, scale: 12, null: false
      t.date :applies_from, null: false
      t.references :updated_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
    end

    add_index :exchange_rates, "tenant_id, LEAST(from_currency, to_currency), GREATEST(from_currency, to_currency), applies_from",
              unique: true, name: "index_exchange_rates_on_pair_and_date"
    add_check_constraint :exchange_rates, "rate > 0", name: "exchange_rates_positive"
    add_check_constraint :exchange_rates, "from_currency <> to_currency", name: "exchange_rates_two_currencies"
  end
end
