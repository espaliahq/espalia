# frozen_string_literal: true

# Event emitted when a person is added to a draft calibration session's
# population (the people whose ratings are calibrated).
#
# The aggregate rejects adding a participant or the facilitator — the
# population never intersects the raters in the room.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :session_id UUID of the calibration session
#   @option data [String] :person_id person_id of the added calibrant
#   @option data [String, nil] :added_by person_id of the actor
#
class AssessmentCycles::Events::CalibrationCalibrantAdded < RubyEventStore::Event
end
