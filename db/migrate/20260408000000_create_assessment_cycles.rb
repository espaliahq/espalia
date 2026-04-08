# frozen_string_literal: true

class CreateAssessmentCycles < ActiveRecord::Migration[8.1]
  def change
    create_table :assessment_cycles, id: :uuid do |t|
      t.references :tenant, type: :uuid, foreign_key: true, null: false
      t.uuid :cycle_id, null: false
      t.uuid :framework_id, null: false
      t.integer :framework_version, null: false
      t.string :name, null: false
      t.string :cycle_type, null: false  # regular | performance_review | promotion_review
      t.string :status, null: false, default: "open"  # open | closed
      t.datetime :opened_at, null: false
      t.datetime :closed_at
      t.uuid :defined_by
      t.timestamps
    end

    add_index :assessment_cycles, [ :tenant_id, :cycle_id ], unique: true,
              name: "idx_assessment_cycles_unique_cycle_id"
    add_index :assessment_cycles, [ :tenant_id, :framework_id ],
              name: "idx_assessment_cycles_by_framework"
    # Partial unique: at most one open cycle per (tenant, framework)
    add_index :assessment_cycles, [ :tenant_id, :framework_id ], unique: true,
              where: "status = 'open'",
              name: "idx_assessment_cycles_one_open_per_framework"
  end
end
