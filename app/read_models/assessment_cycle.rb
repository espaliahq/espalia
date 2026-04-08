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

  has_many :participants, class_name: "AssessmentCycleParticipant",
           primary_key: :cycle_id, foreign_key: :cycle_id,
           inverse_of: :cycle, dependent: :destroy

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
end
