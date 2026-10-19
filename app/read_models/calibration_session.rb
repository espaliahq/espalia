# frozen_string_literal: true

# Projection read model for a calibration session.
#
# Materialised from {AssessmentCycles::CalibrationSessionAggregate}
# events by {AssessmentCycles::Projections::CalibrationSessions}. One
# row per session; the primary key IS the event-carried session_id, so
# URLs and MCP references survive projection rebuilds.
#
# Membership (participants + calibrants) lives on the sibling
# {CalibrationSessionMember} table, written by the same projection.
#
# @see AssessmentCycles::Projections::CalibrationSessions
# @see docs/architecture/calibration-sessions.md
#
class CalibrationSession < ApplicationRecord
  STATUSES = %w[draft started closed].freeze

  acts_as_tenant :tenant

  belongs_to :tenant
  belongs_to :cycle, class_name: "AssessmentCycle",
             primary_key: :cycle_id, foreign_key: :cycle_id,
             inverse_of: false, optional: true
  belongs_to :facilitator, class_name: "Person",
             foreign_key: :facilitator_id,
             inverse_of: false, optional: true

  has_many :members, class_name: "CalibrationSessionMember",
           primary_key: :id, foreign_key: :session_id,
           inverse_of: :session, dependent: :destroy

  validates :cycle_id, presence: true
  validates :framework_id, presence: true
  validates :name, presence: true
  validates :facilitator_id, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :draft, -> { where(status: "draft") }
  scope :started, -> { where(status: "started") }
  scope :closed, -> { where(status: "closed") }
  scope :not_closed, -> { where.not(status: "closed") }
  scope :for_cycle, ->(cycle_id) { where(cycle_id: cycle_id) }
  scope :archived, -> { where.not(archived_at: nil) }
  scope :unarchived, -> { where(archived_at: nil) }

  # Participant (rater) membership rows.
  #
  # @return [ActiveRecord::Relation<CalibrationSessionMember>]
  def participants
    members.where(member_type: "participant")
  end

  # Calibrant (population) membership rows.
  #
  # @return [ActiveRecord::Relation<CalibrationSessionMember>]
  def calibrants
    members.where(member_type: "calibrant")
  end

  # Whether the session is still in draft (participants + population editable).
  #
  # @return [Boolean]
  def draft?
    status == "draft"
  end

  # Whether the session is live (sets frozen, outcomes recordable).
  #
  # @return [Boolean]
  def started?
    status == "started"
  end

  # Whether the session has been closed.
  #
  # @return [Boolean]
  def closed?
    status == "closed"
  end

  # Whether the session has been put away — hidden from the default list,
  # reversible. Only a closed session can be archived.
  #
  # @return [Boolean]
  def archived?
    archived_at.present?
  end
end
