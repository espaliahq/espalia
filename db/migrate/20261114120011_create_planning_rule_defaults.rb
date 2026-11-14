# frozen_string_literal: true

class CreatePlanningRuleDefaults < ActiveRecord::Migration[8.1]
  def change
    create_table :planning_rule_defaults, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: false
      t.string :rule, null: false
      t.jsonb :value, null: false, default: {}
      t.references :updated_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
    end

    add_index :planning_rule_defaults, %i[tenant_id rule], unique: true
  end
end
