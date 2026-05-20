# frozen_string_literal: true

# Projection read model for an assessment cycle.
#
# Materialised from {AssessmentCycles::Aggregate} events by
# {AssessmentCycles::Projections::CurrentState}. One row per cycle,
# scoped to a single tenant. The domain `cycle_id` is separate from
# Rails' `id` primary key — use `cycle_id` as the foreign-key target
# for participants.
#
# @see AssessmentCycles::Projections::CurrentState
#
class AssessmentCycle < ApplicationRecord
  STATUSES = %w[open closed].freeze
  CYCLE_TYPES = %w[regular performance_review promotion_review].freeze

  # Pundit policy lookup: use AssessmentCyclePolicy
  def self.policy_class
    AssessmentCyclePolicy
  end

  acts_as_tenant :tenant

  belongs_to :tenant
  belongs_to :framework, class_name: "FrameworkState::Framework",
             primary_key: :framework_id, foreign_key: :framework_id,
             inverse_of: false, optional: true

  has_many :enrollments, class_name: "AssessmentCycleEnrollment",
           primary_key: :cycle_id, foreign_key: :cycle_id,
           inverse_of: :cycle, dependent: :destroy
  # Progress rows are owned by `PersonDevelopment::Projections::CurrentAssessment`
  # and intentionally lack a `dependent: :destroy` here — cross-projection
  # cascades would cause a single-projection rebuild (e.g.
  # `events:projections:rebuild[assessment_cycles/current_state]`) to wipe
  # another projection's read model. Truncation of progress rows happens
  # exclusively in `CurrentAssessment.reset!`.
  has_many :progress_rows, class_name: "AssessmentCycleProgress",
           primary_key: :cycle_id, foreign_key: :cycle_id,
           inverse_of: false

  validates :cycle_id, presence: true
  validates :framework_id, presence: true
  validates :framework_version, presence: true
  validates :name, presence: true
  validates :cycle_type, presence: true, inclusion: { in: CYCLE_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :opened_at, presence: true

  scope :open_cycles, -> { where(status: "open") }
  scope :closed_cycles, -> { where(status: "closed") }
  scope :for_framework, ->(framework_id) { where(framework_id: framework_id) }

  # Returns a map of [framework_id, person_id] => open AssessmentCycle for the
  # given assignment pairs. Used to batch-load cycles for the assessments index
  # view rather than calling PersonFrameworkAssignment#current_open_cycle per row
  # (N+1 avoidance).
  #
  # Pivots through AssessmentCycleEnrollment so we can reuse its `.active`
  # scope and eager-load the cycle in a single query.
  #
  # @param assignment_pairs [Array<Array(String, String)>] [framework_id, person_id] pairs
  # @return [Hash{Array(String, String) => AssessmentCycle}]
  def self.open_cycles_for(assignment_pairs)
    return {} if assignment_pairs.empty?

    framework_ids = assignment_pairs.map(&:first).uniq
    person_ids = assignment_pairs.map(&:last).uniq

    AssessmentCycleEnrollment
      .active
      .where(person_id: person_ids)
      .eager_load(:cycle)
      .where(assessment_cycles: { framework_id: framework_ids, status: "open" })
      .each_with_object({}) do |enrollment, map|
        cycle = enrollment.cycle
        map[[ cycle.framework_id, enrollment.person_id ]] = cycle
      end
  end

  # Wrapper instances composing enrollment + (optional) progress per
  # person in this cycle. Use this for views that render the unified
  # participant lifecycle. Returns an Array (not a relation).
  #
  # @return [Array<AssessmentCycleParticipation>]
  def participations
    AssessmentCycleParticipation.for_enrollments(enrollments)
  end

  # Whether this cycle is currently open.
  #
  # @return [Boolean]
  def open?
    status == "open"
  end

  # Whether this cycle has been closed.
  #
  # @return [Boolean]
  def closed?
    status == "closed"
  end

  # People who can be enrolled in this cycle: anyone assigned to the
  # framework who is not already an active participant. Ordered by name
  # for stable display in the admin UI.
  #
  # @return [ActiveRecord::Relation<Person>]
  def eligible_people
    return Person.none if framework_id.blank?

    assigned_ids = PersonFrameworkAssignment
      .where(framework_id: framework_id)
      .pluck(:person_id)
    active_participant_ids = enrollments.active.pluck(:person_id)

    Person.where(id: assigned_ids - active_participant_ids).order(:name)
  end
end
