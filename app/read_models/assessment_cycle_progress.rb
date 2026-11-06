# frozen_string_literal: true

# Projection read model for a person's journey within an assessment cycle.
#
# One row per (cycle_id, person_id). Owned exclusively by
# {PersonDevelopment::Projections::CurrentAssessment}. Tracks per-cycle
# progress — started_at, alignment timestamps, terminal aligned state.
# Membership in the cycle (enrolled / concluded / withdrawn) lives on the
# sibling {AssessmentCycleEnrollment} table.
#
# Status state machine:
#   in_progress → started → self_complete / manager_complete → aligning → aligned
#
# On `LeftAssessmentCycle` and `AssessmentCycleConcluded`, the row is
# intentionally retained as a historical record of how far the person got
# (its `aligned_at` also drives next-cycle rating seeding).
# Active-participant queries filter via the enrollment row's status.
#
class AssessmentCycleProgress < ApplicationRecord
  STATUSES = %w[in_progress started self_complete manager_complete aligning aligned].freeze
  INDIVIDUAL_RATING_STATUSES = %w[in_progress started].freeze

  self.table_name = "assessment_cycle_progress"
  # Superseded by home_role_id / home_level_id; dropped once no deployed
  # release writes them.
  self.ignored_columns += %w[joined_role_id joined_level_id]

  acts_as_tenant :tenant

  belongs_to :tenant
  belongs_to :cycle, class_name: "AssessmentCycle",
             primary_key: :cycle_id, foreign_key: :cycle_id,
             inverse_of: false, optional: false
  belongs_to :person, optional: true
  belongs_to :alignment_started_by, class_name: "Person",
             foreign_key: :alignment_started_by_id, inverse_of: false, optional: true
  belongs_to :aligned_by, class_name: "Person",
             foreign_key: :aligned_by_id, inverse_of: false, optional: true

  validates :cycle_id, presence: true
  validates :person_id, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
end
