# frozen_string_literal: true

# Projection read model tracking a person's assignment to a framework.
#
# One row per (person, framework). Stores the assigned role and level.
# Materialised from PersonDevelopment aggregate events by
# {PersonDevelopment::Projections::CurrentAssessment}.
#
# Cycle participation is NOT stored here — it lives on
# {AssessmentCycleParticipant} rows, queryable via {#current_open_cycle}.
#
# @see PersonDevelopment::Projections::CurrentAssessment
# @see AssessmentCycleParticipant
#
class PersonFrameworkAssignment < ApplicationRecord
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
  # Resolved by joining through the person's active participant row to
  # an open cycle for the same framework. Returns the {AssessmentCycle}
  # or nil.
  #
  # @return [AssessmentCycle, nil]
  def current_open_cycle
    AssessmentCycle
      .joins(:participants)
      .where(framework_id: framework_id, status: "open",
             assessment_cycle_participants: { person_id: person_id })
      .where.not(assessment_cycle_participants: { status: "withdrawn" })
      .first
  end
end
