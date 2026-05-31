# frozen_string_literal: true

# Records the role + level a participant is assessed AGAINST for a cycle —
# the cycle-owned snapshot. Captured at enrollment (PersonEnrolled) and
# re-snapshotted mid-cycle (ParticipantRoleLevelChanged) by the
# AssessmentCycles::Projections::CurrentState projection. level_ordinal is
# denormalised so scoring reads it without resolving the level row.
#
# Nullable: enrollments whose PersonEnrolled predates the snapshot remain nil
# (scoring falls back to the person's live assignment level — no regression).
class AddAssessedRoleLevelToCycleEnrollments < ActiveRecord::Migration[8.1]
  def change
    add_column :assessment_cycle_enrollments, :role_id, :uuid
    add_column :assessment_cycle_enrollments, :level_id, :uuid
    add_column :assessment_cycle_enrollments, :level_ordinal, :integer
  end
end
