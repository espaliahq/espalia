class CreateFrameworkSuggestedEdits < ActiveRecord::Migration[8.1]
  def change
    create_table :framework_suggested_edits, id: :uuid do |t|
      t.references :tenant, type: :uuid, foreign_key: true, null: false
      t.uuid :framework_id, null: false
      t.uuid :suggestion_id, null: false
      t.string :target_entity_type, null: false
      t.uuid :target_entity_id, null: false
      t.string :field, null: false
      t.text :current_value
      t.text :suggested_value, null: false
      t.uuid :author_id, null: false
      t.text :rationale
      t.string :status, default: "pending", null: false
      t.uuid :reviewed_by
      t.datetime :reviewed_at
      t.text :reviewer_comment
      t.timestamps
    end

    add_index :framework_suggested_edits, :suggestion_id, unique: true
    add_index :framework_suggested_edits, [ :framework_id, :status ]
    add_index :framework_suggested_edits, [ :target_entity_type, :target_entity_id, :field ],
              name: "index_fw_suggested_edits_on_target"
  end
end
