# frozen_string_literal: true

# Event emitted when a rater is added to a draft calibration session.
#
# If the person was in the calibrant population at the time, a
# {AssessmentCycles::Events::CalibrationCalibrantRemoved} with reason
# "became_participant" is applied first — participants are never
# calibrated in their own session.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :session_id UUID of the calibration session
#   @option data [String] :participant_id person_id of the added rater
#   @option data [String, nil] :added_by person_id of the actor
#
class AssessmentCycles::Events::CalibrationParticipantAdded < RubyEventStore::Event
end
