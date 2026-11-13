# frozen_string_literal: true

class CreateHrisUnitParentProposals < ActiveRecord::Migration[8.1]
  def change
    create_table :hris_unit_parent_proposals, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.uuid :unit_id, null: false
      t.uuid :parent_id, null: false
      t.date :first_seen_on, null: false
      t.timestamps
    end
    add_index :hris_unit_parent_proposals, %i[tenant_id unit_id], unique: true
  end
end
