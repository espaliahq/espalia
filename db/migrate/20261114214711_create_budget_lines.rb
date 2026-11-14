# frozen_string_literal: true

class CreateBudgetLines < ActiveRecord::Migration[8.1]
  def change
    create_table :budget_lines, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.date :starts_on, null: false
      t.date :ends_on, null: false
      t.decimal :amount, precision: 14, scale: 2
      t.string :currency
      t.string :period
      t.decimal :head_count, precision: 8, scale: 2
      t.uuid :role_id
      t.uuid :level_id
      t.string :role_name
      t.string :level_name
      t.string :location, null: false, default: ""
      t.string :cost_centre, null: false, default: ""
      t.string :origin, null: false
      t.date :approved_on
      t.references :updated_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
    end

    add_check_constraint :budget_lines, "starts_on <= ends_on", name: "budget_lines_period_ordered"
    add_check_constraint :budget_lines, "amount IS NOT NULL OR head_count IS NOT NULL", name: "budget_lines_amount_or_head_count"
    add_check_constraint :budget_lines, "amount IS NULL OR (amount >= 0 AND currency IS NOT NULL AND period IS NOT NULL)",
                         name: "budget_lines_amount_has_currency"
    add_check_constraint :budget_lines, "head_count IS NULL OR head_count > 0", name: "budget_lines_head_count_positive"
  end
end
