# frozen_string_literal: true

# Projection read model for a person's membership in an assessment cycle.
#
# One row per (cycle_id, person_id). Owned exclusively by
# {AssessmentCycles::Projections::CurrentState}. Tracks enrollment lifecycle
# only — enrolled / concluded / withdrawn. Per-cycle journey progress
# (started_at, alignment timestamps) lives on the sibling
# {AssessmentCycleProgress} table, owned by
# {PersonDevelopment::Projections::CurrentAssessment}. The two are joined
# via {AssessmentCycleParticipation} for callers that need a unified view.
#
class AssessmentCycleEnrollment < ApplicationRecord
  # The unenroll route addresses this row by primary key
  # (DELETE /assessment_cycles/:cycle/enrollments/:id), so the PK must be a
  # pure function of event-sourced data — a projection rebuild reissuing
  # random ids would 404 any captured URL (see event-sourcing.md).
  include DeterministicId
  deterministic_id_from :cycle_id, :person_id

  # enrolled  — live membership in an (open) cycle
  # concluded — the cycle closed with the person still enrolled; their
  #             participation stands as part of the cycle's historical
  #             cohort. An unrated enrollment still concludes.
  # withdrawn — person-scoped removal (opted out, left the company,
  #             enrolled by mistake) — the participation was revoked.
  STATUSES = %w[enrolled concluded withdrawn].freeze

  # Pundit policy lookup: reuse the AssessmentCyclePolicy
  def self.policy_class
    AssessmentCyclePolicy
  end

  acts_as_tenant :tenant

  belongs_to :tenant
  belongs_to :cycle, class_name: "AssessmentCycle",
             primary_key: :cycle_id, foreign_key: :cycle_id,
             inverse_of: :enrollments, optional: false
  belongs_to :person, optional: true

  validates :cycle_id, presence: true
  validates :person_id, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :enrolled_at, presence: true

  scope :for_person, ->(person_id) { where(person_id: person_id) }
  # Participations that stand — enrolled AND concluded. Cohort reporting,
  # participant counts, and manager cohort access all read this scope so a
  # closed cycle keeps its cohort. Callers that mean "live membership in an
  # ongoing cycle" additionally join on the cycle's open status (concluded
  # rows only ever exist on closed cycles).
  scope :active,     -> { where.not(status: "withdrawn") }
  scope :concluded,  -> { where(status: "concluded") }
  scope :withdrawn,  -> { where(status: "withdrawn") }
end
