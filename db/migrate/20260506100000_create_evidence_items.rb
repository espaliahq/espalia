# frozen_string_literal: true

class CreateEvidenceItems < ActiveRecord::Migration[8.1]
  def change
    create_table :evidence_items, id: :uuid do |t|
      t.references :tenant, type: :uuid, foreign_key: true, null: false
      t.uuid :person_id,            null: false
      t.uuid :framework_id,         null: false
      t.uuid :capability_stable_id, null: false
      t.integer :level_ordinal,     null: false

      t.string :source,             null: false  # "self" | "manager" | "peer"
      t.string :evidence_type,      null: false
      t.string :custom_type_label
      t.string :title
      t.text   :content,            null: false

      t.jsonb  :external_reference, default: {}, null: false

      t.uuid   :author_id,          null: false

      t.string :link_status, default: "active", null: false  # "active" | "withdrawn"
      # Naming intentionally matches `assessment_cycle_enrollments.withdrawal_reason`
      # — existing project convention pairs `withdrawn_at` / `withdrawn_by_id` /
      # `withdrawal_reason` rather than the symmetric `withdrawn_*` triple.
      t.text   :withdrawal_reason
      t.uuid   :withdrawn_by_id
      t.datetime :withdrawn_at

      t.datetime :recorded_at, null: false
      t.timestamps
    end

    add_index :evidence_items, [ :person_id, :framework_id, :capability_stable_id, :level_ordinal ],
              name: "idx_evidence_items_anchor"
    add_index :evidence_items, [ :tenant_id, :person_id, :link_status ],
              name: "idx_evidence_items_tenant_person_status"
    add_index :evidence_items, :author_id
    add_index :evidence_items, :withdrawn_by_id,
              where: "withdrawn_by_id IS NOT NULL",
              name: "idx_evidence_items_withdrawn_by_id"

    add_foreign_key :evidence_items, :people, column: :author_id, on_delete: :restrict
    add_foreign_key :evidence_items, :people, column: :withdrawn_by_id, on_delete: :nullify
  end
end
