# frozen_string_literal: true

# Event emitted when a calibration session goes live.
#
# Freezes the participant and calibrant sets — the snapshots are
# carried on this event (the ADR-19 enrollment-snapshot instinct:
# mid-session org changes must not reshuffle the room or the
# denominators on screen). Draft-phase curation ends here.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :session_id UUID of the calibration session
#   @option data [Array<String>] :participant_ids frozen rater set
#   @option data [Array<String>] :calibrant_person_ids frozen population
#   @option data [String, nil] :started_by_id person_id of the facilitator who started it
#
class AssessmentCycles::Events::CalibrationSessionStarted < RubyEventStore::Event
end
