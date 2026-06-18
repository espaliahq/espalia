# frozen_string_literal: true

# Projection read model tracking a person's assignment to a framework.
#
# One row per (person, framework). Stores the assigned role and level.
# Materialised from PersonDevelopment aggregate events by
# {PersonDevelopment::Projections::CurrentAssessment}.
#
# Cycle participation is NOT stored here — enrollment lives on
# {AssessmentCycleEnrollment}, journey progress on {AssessmentCycleProgress}.
# Both are joined for read sites via {AssessmentCycleParticipation};
# {#current_open_cycle_participation} returns the wrapper.
#
# @see PersonDevelopment::Projections::CurrentAssessment
# @see AssessmentCycleParticipation
#
class PersonFrameworkAssignment < ApplicationRecord
  # The primary key is the externally-addressed identity (`/assessments/:id`,
  # all nested assessment routes, the `assessment://<id>` MCP resource, and
  # every assessment Operation). Derive it deterministically from the natural
  # key so a projection rebuild reproduces the same id instead of reissuing a
  # random one and breaking in-flight URLs. See {DeterministicId}.
  include DeterministicId
  deterministic_id_from :person_id, :framework_id

  # Pundit policy lookup: use AssessmentPolicy
  def self.policy_class
    AssessmentPolicy
  end

  acts_as_tenant :tenant

  belongs_to :tenant
  belongs_to :framework, class_name: "FrameworkState::Framework",
             primary_key: :framework_id, foreign_key: :framework_id,
             inverse_of: false, optional: true
  belongs_to :role, class_name: "FrameworkState::Role",
             primary_key: :role_id, foreign_key: :role_id,
             inverse_of: false, optional: true
  belongs_to :level, class_name: "FrameworkState::Level",
             primary_key: :level_id, foreign_key: :level_id,
             inverse_of: false, optional: true

  validates :person_id, presence: true
  validates :framework_id, presence: true
  validates :role_id, presence: true
  validates :level_id, presence: true

  scope :for_person, ->(person_id) { where(person_id: person_id) }

  # The currently open cycle for this (framework, person), if any.
  #
  # Resolved by joining through the person's active enrollment row to
  # an open cycle for the same framework. Returns the {AssessmentCycle}
  # or nil.
  #
  # @return [AssessmentCycle, nil]
  def current_open_cycle
    AssessmentCycle
      .joins(:enrollments)
      .where(framework_id: framework_id, status: "open",
             assessment_cycle_enrollments: { person_id: person_id })
      .where.not(assessment_cycle_enrollments: { status: "withdrawn" })
      .first
  end

  # The participation wrapper (enrollment + optional progress) for this
  # person on the current open cycle. Carries lifecycle status, used by
  # {AssessmentPolicy} to gate rating commands.
  #
  # @return [AssessmentCycleParticipation, nil]
  def current_open_cycle_participation
    cycle = current_open_cycle
    return nil unless cycle

    AssessmentCycleParticipation.find_by(cycle_id: cycle.cycle_id, person_id: person_id)
  end
end
