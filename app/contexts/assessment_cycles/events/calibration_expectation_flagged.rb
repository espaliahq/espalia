# frozen_string_literal: true

# Event emitted when the room flags a behavioural expectation as unclear
# during a live calibration session. The flag itself is raised on the
# FRAMEWORK stream as a clarification (a non-proposal suggestion — see
# Frameworks::Events::ClarificationRequested); this event records the session
# provenance and carries the resulting suggestion_id so the follow-through
# page can track the discussion's status.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :session_id UUID of the calibration session
#   @option data [String] :capability_stable_id cross-version capability id
#   @option data [Integer] :level_ordinal the level whose expectation is unclear
#   @option data [String] :suggestion_id UUID of the framework clarification raised
#   @option data [String, nil] :flagged_by_id person_id of the actor (the facilitator)
#   @option data [String, nil] :reason the room's note on what is unclear
#
class AssessmentCycles::Events::CalibrationExpectationFlagged < RubyEventStore::Event
end
