# frozen_string_literal: true

# Event emitted when a rater is removed from a draft calibration session.
#
# Removing a participant does NOT remove their reports from the
# calibrant population — the population is a curated list, and reports
# whose rater isn't in the room remain valid reference points (rendered
# muted, exempt from outcomes).
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :session_id UUID of the calibration session
#   @option data [String] :participant_id person_id of the removed rater
#   @option data [String, nil] :removed_by person_id of the actor
#
class AssessmentCycles::Events::CalibrationParticipantRemoved < RubyEventStore::Event
end
