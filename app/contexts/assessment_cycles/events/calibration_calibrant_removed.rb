# frozen_string_literal: true

# Event emitted when a person is removed from a draft calibration
# session's population.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :session_id UUID of the calibration session
#   @option data [String] :person_id person_id of the removed calibrant
#   @option data [String] :reason "manual" (facilitator curation) or
#     "became_participant" (auto-removed when promoted to rater)
#   @option data [String, nil] :removed_by person_id of the actor
#
class AssessmentCycles::Events::CalibrationCalibrantRemoved < RubyEventStore::Event
end
