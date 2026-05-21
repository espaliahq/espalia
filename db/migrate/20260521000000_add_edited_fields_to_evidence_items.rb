# frozen_string_literal: true

class AddEditedFieldsToEvidenceItems < ActiveRecord::Migration[8.1]
  def change
    add_column :evidence_items, :edited_at, :datetime
    add_column :evidence_items, :edited_by_id, :uuid

    add_index :evidence_items, :edited_by_id,
              where: "edited_by_id IS NOT NULL",
              name: "idx_evidence_items_edited_by_id"

    add_foreign_key :evidence_items, :people, column: :edited_by_id, on_delete: :nullify
  end
end
