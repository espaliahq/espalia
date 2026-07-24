# frozen_string_literal: true

# Event emitted when a calibration session is closed.
#
# Closing is terminal. Emitted by the facilitator, or by the
# cycle-close sync handler when the parent assessment cycle closes
# (reason "cycle_closed"). The aggregate treats close as a no-op when
# already closed, so the sync path is replay/retry-safe.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :session_id UUID of the calibration session
#   @option data [String] :reason "facilitator" or "cycle_closed"
#   @option data [String, nil] :closed_by_id person_id of the closer (nil for cycle_closed sync)
#
class AssessmentCycles::Events::CalibrationSessionClosed < RubyEventStore::Event
end
