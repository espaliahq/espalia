# frozen_string_literal: true

# Projection read model: alignment started against one role for one person
# in one cycle (ADR-22).
#
# One row per (cycle_id, person_id, role_id), the home role included. Owned
# exclusively by {PersonDevelopment::Projections::CurrentAssessment}. The
# home role's lifecycle is ALSO on {AssessmentCycleProgress#status}, which
# every cohort reader keeps reading; this table is what lets a reader see a
# conversation about another role.
#
# A row exists only once alignment has started: `status` is `aligning`
# until completion, then `aligned`, and back to `aligning` on re-open.
class AssessmentCycleRoleAlignment < ApplicationRecord
  STATUSES = %w[aligning aligned].freeze

  include DeterministicId
  deterministic_id_from :cycle_id, :person_id, :role_id

  acts_as_tenant :tenant

  belongs_to :tenant
  belongs_to :alignment_started_by, class_name: "Person",
             foreign_key: :alignment_started_by_id, inverse_of: false, optional: true
  belongs_to :aligned_by, class_name: "Person",
             foreign_key: :aligned_by_id, inverse_of: false, optional: true

  validates :cycle_id, :person_id, :framework_id, :role_id, :alignment_started_at, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :for_participation, ->(cycle_id:, person_id:) { where(cycle_id: cycle_id, person_id: person_id) }
  scope :lens, -> { where(home: false) }

  # @return [Boolean]
  def aligned? = status == "aligned"
end
