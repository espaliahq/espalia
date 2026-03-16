class CreateFrameworkMigrationMappings < ActiveRecord::Migration[8.1]
  def change
    create_table :framework_migration_mappings, id: :uuid do |t|
      t.references :tenant, type: :uuid, foreign_key: true, null: false
      t.uuid :framework_id, null: false
      t.uuid :mapping_id, null: false
      t.integer :published_version, null: false
      t.uuid :from_stable_id
      t.uuid :to_stable_id
      t.string :mapping_type, null: false
      t.boolean :requires_reassessment, default: false, null: false
      t.string :reason
      t.timestamps
    end

    add_index :framework_migration_mappings, :mapping_id, unique: true
    add_index :framework_migration_mappings, [ :framework_id, :published_version ]
  end
end
