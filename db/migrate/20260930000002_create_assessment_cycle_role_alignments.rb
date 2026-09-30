# frozen_string_literal: true

# One row per role a person's alignment has been started against in a cycle
# (ADR-22) — the home role included, so a reader asking "which roles are in
# conversation?" needs one table. `assessment_cycle_progress` keeps the home
# role's lifecycle, which the list, the cohort report and calibration read.
#
# `whole_assessment` marks a start from before per-role alignment: it froze
# every cell, and still does.
class CreateAssessmentCycleRoleAlignments < ActiveRecord::Migration[8.1]
  def change
    create_table :assessment_cycle_role_alignments, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: true
      t.uuid :cycle_id, null: false
      t.uuid :person_id, null: false
      t.uuid :framework_id, null: false
      t.uuid :role_id, null: false
      t.integer :level_ordinal
      t.boolean :home, null: false, default: false
      t.boolean :whole_assessment, null: false, default: false
      t.string :status, null: false, default: "aligning"
      t.datetime :alignment_started_at, null: false
      t.uuid :alignment_started_by_id
      t.datetime :aligned_at
      t.uuid :aligned_by_id
      t.integer :aligned_framework_version
      t.datetime :reopened_at
      t.uuid :reopened_by_id
      t.timestamps
    end

    add_index :assessment_cycle_role_alignments, %i[cycle_id person_id role_id],
      unique: true, name: "idx_assessment_cycle_role_alignments_unique"
    add_index :assessment_cycle_role_alignments, %i[tenant_id person_id],
      name: "idx_assessment_cycle_role_alignments_by_person"
  end
end
