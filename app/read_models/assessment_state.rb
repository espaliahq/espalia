# frozen_string_literal: true

# Projection read model for current assessment state.
#
# One row per (person, framework, capability_stable_id).
# Tracks the latest self-rating, manager rating, and aligned level
# for each capability in the person's current assessment.
#
# Materialised from PersonDevelopment aggregate events by
# {PersonDevelopment::Projections::CurrentAssessment}.
#
class AssessmentState < ApplicationRecord
  MIGRATION_STATUSES = %w[not_flagged flagged resolved].freeze

  acts_as_tenant :tenant

  belongs_to :tenant

  validates :person_id, presence: true
  validates :framework_id, presence: true
  validates :capability_stable_id, presence: true
  validates :migration_status, presence: true, inclusion: { in: MIGRATION_STATUSES }

  scope :for_person, ->(person_id) { where(person_id: person_id) }
  scope :for_framework, ->(framework_id) { where(framework_id: framework_id) }
  scope :self_rated, -> { where.not(self_rated_level_id: nil) }
end
