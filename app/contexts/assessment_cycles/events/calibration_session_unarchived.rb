# frozen_string_literal: true

# Event emitted when an archived calibration session is restored to the
# default list. The session stays closed.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :session_id UUID of the calibration session
#   @option data [String, nil] :unarchived_by_id person_id of the actor
#
class AssessmentCycles::Events::CalibrationSessionUnarchived < RubyEventStore::Event
end
