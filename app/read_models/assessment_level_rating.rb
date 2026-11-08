# frozen_string_literal: true

# Projection read model for per-level capability assessments.
#
# One row per (cycle_id, person, framework, capability_stable_id, level_ordinal).
# Stores independent frequency ratings at each level of a capability,
# scoped to a specific assessment cycle. This preserves history across
# cycles and supports both "latest rating" and "rating in cycle X"
# queries directly on the read model.
#
# Frequency values: "none", "some", "occasional", "consistent"; their scoring
# weights are PersonDevelopment::Scoring::FREQUENCY.
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
  FREQUENCIES = %w[none some occasional consistent].freeze
  MIGRATION_STATUSES = %w[not_flagged flagged resolved].freeze
  SOURCES = %w[human agent seeded].freeze

  acts_as_tenant :tenant

  belongs_to :tenant
  belongs_to :cycle, class_name: "AssessmentCycle",
             primary_key: :cycle_id, foreign_key: :cycle_id,
             inverse_of: false, optional: false

  validates :cycle_id, presence: true
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
  scope :for_cycle, ->(cycle_id) { where(cycle_id: cycle_id) }
  scope :self_rated, -> { where.not(self_rated_frequency: nil) }
  scope :aligned, -> { where.not(aligned_frequency: nil) }
  scope :seeded, -> { where(source: "seeded") }
  scope :human_entered, -> { where(source: "human") }

  # Ratings inside one role's scope, or inside each person's own scope
  # (ADR-22). Every reader that counts or scores ratings goes through this
  # or through {.across_all_roles}; the `Espalia/RatingsMustBeRoleScoped`
  # cop enforces it.
  #
  # @param scope [Assessments::RoleScope, Hash{String => Assessments::RoleScope}]
  #   one scope, or person_id => that person's scope for a cohort read
  # @return [ActiveRecord::Relation]
  def self.within(scope)
    return within_cells(scope.cells) unless scope.is_a?(Hash)

    groups = scope.group_by { |_, role_scope| role_scope }
      .reject { |role_scope, _| role_scope.empty? }
    return none if groups.empty?

    groups.map { |role_scope, pairs| within_cells(role_scope.cells).where(person_id: pairs.map(&:first)) }
      .reduce(:or)
  end

  # Every rating regardless of role — for readers whose answer is about the
  # person rather than any one role: activity history, cross-cycle seeding,
  # a cell a caller has already named. Says so at the call site.
  #
  # @return [ActiveRecord::Relation]
  def self.across_all_roles
    all
  end

  # @param cells [Set<Array(String, Integer)>]
  # @return [ActiveRecord::Relation]
  #
  # Not `where([:capability_stable_id, :level_ordinal] => cells)`: Rails 8.1
  # renders that as one OR per cell and an empty list as `WHERE ()`.
  def self.within_cells(cells)
    return none if cells.empty?

    stable_ids, ordinals = cells.to_a.transpose
    where(
      "(assessment_level_ratings.capability_stable_id, assessment_level_ratings.level_ordinal) " \
      "IN (SELECT * FROM unnest(ARRAY[?]::uuid[], ARRAY[?]::integer[]))",
      stable_ids, ordinals
    )
  end
  private_class_method :within_cells

  # Whether the self side still shows a carried-forward (seeded) value the
  # person hasn't confirmed or changed. Per-side — the row-level `source`
  # flips to "human" on any human touch and can't answer this.
  #
  # @return [Boolean]
  def self_rating_carried?
    self_rating_source == "seeded"
  end

  # Whether the manager side still shows a carried-forward (seeded) value.
  #
  # @return [Boolean]
  def manager_rating_carried?
    manager_rating_source == "seeded"
  end
end
