# frozen_string_literal: true

class CreateFrameworkStates < ActiveRecord::Migration[8.1]
  def change
    create_table :framework_states, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.uuid :framework_id, null: false
      t.string :name, null: false
      t.integer :current_published_version, default: 0, null: false
      t.boolean :draft_in_progress, default: false, null: false
      t.integer :draft_version
      t.decimal :mastery_threshold, precision: 5, scale: 2, null: true
      t.decimal :promotion_score_threshold, precision: 5, scale: 2, null: true
      t.timestamps
    end

    add_index :framework_states, [ :tenant_id, :framework_id ], unique: true
  end
end
