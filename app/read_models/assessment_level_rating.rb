# frozen_string_literal: true

# Projection read model for per-level capability assessments.
#
# One row per (person, framework, capability_stable_id, level_ordinal).
# Stores independent frequency ratings at each level of a capability,
# enabling multi-dimensional assessment: you may be assessed at L2, L3,
# and L4 for the same capability independently.
#
# Frequency values: "some" (0.25x), "occasional" (0.5x), "consistent" (1.0x)
#
# Fallback chain for effective_frequency used in scoring:
#   aligned_frequency → manager_rated_frequency → self_rated_frequency → default
#
# Default when unassessed:
#   1.0 for level_ordinal <= person's assigned level (assume consistent)
#   0.0 for level_ordinal >  person's assigned level (not expected)
#
# Agreed level is derived (never stored): highest level_ordinal where
# effective_frequency == "consistent".
#
# Materialised from PersonDevelopment aggregate events by
# {PersonDevelopment::Projections::CurrentAssessment}.
#
class AssessmentLevelRating < ApplicationRecord
  FREQUENCIES = %w[some occasional consistent].freeze
  MIGRATION_STATUSES = %w[not_flagged flagged resolved].freeze
  SOURCES = %w[human agent].freeze

  acts_as_tenant :tenant

  belongs_to :tenant

  validates :person_id, presence: true
  validates :framework_id, presence: true
  validates :capability_stable_id, presence: true
  validates :level_ordinal, presence: true
  validates :migration_status, presence: true, inclusion: { in: MIGRATION_STATUSES }
  validates :source, presence: true, inclusion: { in: SOURCES }
  validates :self_rated_frequency, inclusion: { in: FREQUENCIES }, allow_nil: true
  validates :manager_rated_frequency, inclusion: { in: FREQUENCIES }, allow_nil: true
  validates :aligned_frequency, inclusion: { in: FREQUENCIES }, allow_nil: true

  scope :for_person, ->(person_id) { where(person_id: person_id) }
  scope :for_framework, ->(framework_id) { where(framework_id: framework_id) }
  scope :for_capability, ->(stable_id) { where(capability_stable_id: stable_id) }
  scope :self_rated, -> { where.not(self_rated_frequency: nil) }
  scope :aligned, -> { where.not(aligned_frequency: nil) }
end
