# frozen_string_literal: true

# Event emitted when a calibration session's display name changes.
#
# Allowed in every status: a name is a label, not a fact the room argued
# over. The aggregate strips whitespace, refuses a blank name and skips an
# unchanged one, so every instance of this event is a real change.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :session_id UUID of the calibration session
#   @option data [String] :name the new name, stripped
#   @option data [String] :previous_name the name it replaced, so the session
#     log can say what the session used to be called
#   @option data [String, nil] :renamed_by_id person_id of the actor
#
class AssessmentCycles::Events::CalibrationSessionRenamed < RubyEventStore::Event
end
