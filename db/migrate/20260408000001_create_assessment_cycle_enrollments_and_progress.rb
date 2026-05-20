# frozen_string_literal: true

# Two read-model tables for participant lifecycle, one per projection owner.
#
# `assessment_cycle_enrollments` — written exclusively by
# `AssessmentCycles::Projections::CurrentState`. Membership in a cycle:
# enrolled / withdrawn.
#
# `assessment_cycle_progress` — written exclusively by
# `PersonDevelopment::Projections::CurrentAssessment`. Per-cycle journey:
# started_at, alignment timestamps, terminal aligned state.
#
# The two are joined on `(cycle_id, person_id)` via the
# `AssessmentCycleParticipation` PORO wrapper. See
# `docs/guidelines/event-sourcing.md` — every read-model table has exactly
# one projection writer.
class CreateAssessmentCycleEnrollmentsAndProgress < ActiveRecord::Migration[8.1]
  def change
    create_table :assessment_cycle_enrollments, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, foreign_key: true, null: false
      t.uuid :cycle_id, null: false
      t.uuid :person_id, null: false
      t.string :status, null: false, default: "enrolled"
      # enrolled | withdrawn
      t.datetime :enrolled_at, null: false
      t.datetime :withdrawn_at
      t.string :withdrawal_reason
      t.timestamps
    end

    add_index :assessment_cycle_enrollments, [ :cycle_id, :person_id ], unique: true,
              name: "idx_assessment_cycle_enrollments_unique"
    add_index :assessment_cycle_enrollments, [ :tenant_id, :person_id, :status ],
              name: "idx_assessment_cycle_enrollments_by_person_status"

    create_table :assessment_cycle_progress, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, foreign_key: true, null: false
      t.uuid :cycle_id, null: false
      t.uuid :person_id, null: false
      t.string :status, null: false, default: "in_progress"
      # in_progress | self_complete | manager_complete | aligning | aligned
      t.datetime :started_at
      t.datetime :self_completed_at
      t.datetime :manager_completed_at
      t.datetime :alignment_started_at
      t.uuid :alignment_started_by_id
      t.datetime :aligned_at
      t.uuid :aligned_by_id
      t.timestamps
    end

    add_index :assessment_cycle_progress, [ :cycle_id, :person_id ], unique: true,
              name: "idx_assessment_cycle_progress_unique"
    add_index :assessment_cycle_progress, [ :tenant_id, :person_id, :status ],
              name: "idx_assessment_cycle_progress_by_person_status"
    add_index :assessment_cycle_progress, :alignment_started_by_id,
              name: "idx_assessment_cycle_progress_alignment_started_by_id",
              where: "alignment_started_by_id IS NOT NULL"
    add_index :assessment_cycle_progress, :aligned_by_id,
              name: "idx_assessment_cycle_progress_aligned_by_id",
              where: "aligned_by_id IS NOT NULL"

    add_foreign_key :assessment_cycle_progress, :people,
      column: :alignment_started_by_id, on_delete: :nullify
    add_foreign_key :assessment_cycle_progress, :people,
      column: :aligned_by_id, on_delete: :nullify
  end
end
