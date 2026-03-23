# frozen_string_literal: true

class CreatePersonFrameworkAssignments < ActiveRecord::Migration[8.1]
  def change
    create_table :person_framework_assignments, id: :uuid do |t|
      t.references :tenant, type: :uuid, foreign_key: true, null: false
      t.uuid :person_id,      null: false
      t.uuid :framework_id,   null: false
      t.uuid :role_id,        null: false
      t.uuid :level_id,       null: false
      t.uuid :current_cycle_id
      t.string :cycle_status,  default: "none", null: false  # none | open | completed
      t.string :cycle_name
      t.timestamps
    end

    add_index :person_framework_assignments,
              [ :tenant_id, :person_id, :framework_id ],
              unique: true, name: "idx_person_framework_assignments_unique"
    add_index :person_framework_assignments, [ :person_id, :framework_id ]
  end
end
