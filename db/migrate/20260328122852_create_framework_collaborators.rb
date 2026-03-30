# frozen_string_literal: true

class CreateFrameworkCollaborators < ActiveRecord::Migration[8.0]
  def change
    create_table :framework_collaborators, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.uuid :framework_id, null: false
      t.uuid :person_id, null: false
      t.string :role, null: false
      t.string :scope_type
      t.uuid :scope_id

      t.timestamps
    end

    add_index :framework_collaborators,
              [ :framework_id, :person_id, :role, :scope_type, :scope_id ],
              unique: true, name: "idx_framework_collaborators_unique"
    add_index :framework_collaborators, [ :framework_id, :person_id ]
    add_index :framework_collaborators, :person_id
  end
end
