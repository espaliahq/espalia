# frozen_string_literal: true

# Projection read model for a person's participation in an assessment cycle.
#
# One row per (cycle_id, person_id). Tracks the per-person lifecycle
# within a cycle: enrolled → started (on first rating) → aligned
# (on AssessmentAligned). `withdrawn` is set when the person is
# unenrolled or the cycle closes while they are still enrolled.
#
# Materialised by {AssessmentCycles::Projections::CurrentState} and
# {PersonDevelopment::Projections::CurrentAssessment}.
#
class AssessmentCycleParticipant < ApplicationRecord
  STATUSES = %w[enrolled started self_complete manager_complete aligned withdrawn].freeze

  # Pundit policy lookup: reuse the AssessmentCyclePolicy
  def self.policy_class
    AssessmentCyclePolicy
  end

  acts_as_tenant :tenant

  belongs_to :tenant
  belongs_to :cycle, class_name: "AssessmentCycle",
             primary_key: :cycle_id, foreign_key: :cycle_id,
             inverse_of: :participants, optional: false
  belongs_to :person, optional: true

  validates :cycle_id, presence: true
  validates :person_id, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :enrolled_at, presence: true

  scope :for_person, ->(person_id) { where(person_id: person_id) }
  scope :active, -> { where.not(status: "withdrawn") }
  scope :withdrawn, -> { where(status: "withdrawn") }
end
