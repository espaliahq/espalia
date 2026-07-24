# frozen_string_literal: true

# Projection read model for a calibration session membership — one row
# per person per session, either a participant (rater in the room) or a
# calibrant (person whose ratings are calibrated). The two roles are
# mutually exclusive per session (aggregate invariant), so
# (session_id, person_id) is unique.
#
# Written exclusively by {AssessmentCycles::Projections::CalibrationSessions}.
# Rows are deleted on removal — the curation history lives on the stream.
#
class CalibrationSessionMember < ApplicationRecord
  MEMBER_TYPES = %w[participant calibrant].freeze

  acts_as_tenant :tenant

  belongs_to :tenant
  belongs_to :session, class_name: "CalibrationSession",
             primary_key: :id, foreign_key: :session_id,
             inverse_of: :members
  belongs_to :person, foreign_key: :person_id,
             inverse_of: false, optional: true

  validates :session_id, presence: true
  validates :person_id, presence: true
  validates :member_type, presence: true, inclusion: { in: MEMBER_TYPES }

  scope :participants, -> { where(member_type: "participant") }
  scope :calibrants, -> { where(member_type: "calibrant") }
end
