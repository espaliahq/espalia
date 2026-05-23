# frozen_string_literal: true

class CreatePersonDevelopmentComments < ActiveRecord::Migration[8.1]
  def change
    create_table :person_development_comments, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, foreign_key: true, null: false
      t.uuid :person_id,    null: false
      t.uuid :framework_id, null: false

      # Polymorphic-ish anchor. V1 uses "assessment_cell" with a
      # (capability_stable_id, level_ordinal) coordinate. Future
      # commentable types (growth_plan, focus_area, check_in) carry
      # their own identifier columns nullable here.
      t.string :commentable_type, null: false

      # Assessment-cell anchor — same coordinate system as ratings and
      # evidence so comments survive role transitions and framework
      # version drift. Nullable so future commentable types (growth_plan
      # etc) can leave them blank.
      t.uuid    :capability_stable_id
      t.integer :level_ordinal

      # Threading. NULL for a top-level comment; otherwise points to the
      # parent comment's id. Replies inherit the parent's commentable
      # coordinates — they live in the same thread.
      t.uuid :parent_id

      t.text :body, null: false

      t.uuid     :author_id,  null: false
      t.datetime :posted_at,  null: false

      t.datetime :edited_at
      t.uuid     :edited_by_id

      # Soft-delete: a removed comment keeps its row so threads stay
      # coherent and evidence pointing to the comment still resolves.
      t.string   :status, default: "active", null: false  # "active" | "deleted"
      t.datetime :deleted_at
      t.uuid     :deleted_by_id
      t.text     :deletion_reason

      t.timestamps
    end

    add_index :person_development_comments,
              [ :person_id, :framework_id, :commentable_type, :capability_stable_id, :level_ordinal ],
              name: "idx_pdc_cell_anchor"
    add_index :person_development_comments, :parent_id,
              where: "parent_id IS NOT NULL",
              name: "idx_pdc_parent"
    add_index :person_development_comments, [ :tenant_id, :person_id, :status ],
              name: "idx_pdc_tenant_person_status"
    add_index :person_development_comments, :author_id

    add_foreign_key :person_development_comments, :people, column: :author_id, on_delete: :restrict
    add_foreign_key :person_development_comments, :people, column: :edited_by_id, on_delete: :nullify
    add_foreign_key :person_development_comments, :people, column: :deleted_by_id, on_delete: :nullify
    add_foreign_key :person_development_comments, :person_development_comments,
                    column: :parent_id, on_delete: :restrict
  end
end
