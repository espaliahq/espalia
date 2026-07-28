# frozen_string_literal: true

# Event emitted when the facilitator records a free-text minute during a
# live calibration session — the room's narrative, optionally anchored to a
# capability or a person ("add X to the org-wide session", "revisit L4
# wording next cycle").
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :session_id UUID of the calibration session
#   @option data [String] :body the note (required)
#   @option data [String, nil] :capability_stable_id optional capability anchor
#   @option data [String, nil] :person_id optional person anchor (a calibrant)
#   @option data [String, nil] :recorded_by_id person_id of the actor
#
class AssessmentCycles::Events::CalibrationNoteRecorded < RubyEventStore::Event
end
