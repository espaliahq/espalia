# frozen_string_literal: true

class CreatePeople < ActiveRecord::Migration[8.1]
  def change
    create_table :people, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :manager, type: :uuid, null: true, foreign_key: { to_table: :people }

      t.string :name, null: false
      t.string :email, null: false
      t.string :job_title
      t.string :role_id
      t.string :level_id
      t.string :external_id
      t.string :hris_source
      t.integer :hris_level_ordinal

      t.timestamps
    end

    add_index :people, [ :tenant_id, :email ], unique: true
    add_index :people, [ :tenant_id, :external_id ], unique: true, where: "external_id IS NOT NULL"
  end
end
