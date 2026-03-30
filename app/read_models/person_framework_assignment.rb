# frozen_string_literal: true

# Projection read model tracking a person's assignment to a framework.
#
# One row per (person, framework). Stores the assigned role, level, and
# current assessment cycle status. Materialised from PersonDevelopment
# aggregate events by {PersonDevelopment::Projections::CurrentAssessment}.
#
# @see PersonDevelopment::Projections::CurrentAssessment
#
class PersonFrameworkAssignment < ApplicationRecord
  CYCLE_STATUSES = %w[none open completed].freeze

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
  validates :cycle_status, presence: true, inclusion: { in: CYCLE_STATUSES }

  scope :for_person, ->(person_id) { where(person_id: person_id) }
  scope :with_open_cycle, -> { where(cycle_status: "open") }

  # Whether the person currently has an open assessment cycle.
  #
  # @return [Boolean]
  def cycle_open?
    cycle_status == "open"
  end
end
