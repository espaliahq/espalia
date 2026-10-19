# frozen_string_literal: true

# Event emitted when a closed calibration session is put away.
#
# Archiving hides the session from the default list and nothing else: the
# stream, the outcomes and the session page all stay, and
# {CalibrationSessionUnarchived} puts it back. Only a closed session can be
# archived; the aggregate treats archiving an archived session as a no-op.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :session_id UUID of the calibration session
#   @option data [String, nil] :archived_by_id person_id of the actor
#
class AssessmentCycles::Events::CalibrationSessionArchived < RubyEventStore::Event
end
