# frozen_string_literal: true

# Event emitted on a person's development stream when a calibration session
# asks their rater to revisit a manager rating — the PD-side mirror of
# {AssessmentCycles::Events::CalibrationRatingRevisitRequested}, so the nudge
# surfaces in the assessment activity feed where the rater works.
#
# Value-free: carries the room's note, never a suggested target rating.
# Resolution is rating-change-based and computed at read time — a manager
# rating recorded for the cell after this event settles every open revisit
# against it at once (no resolution event).
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :capability_stable_id cross-version capability id
#   @option data [Integer] :level_ordinal the rated level
#   @option data [String] :calibration_session_id provenance — the session that asked
#   @option data [String, nil] :session_name display name at event time
#   @option data [String] :rater_id person_id of the rater being asked
#   @option data [String] :note the room's discussion note
#   @option data [String, nil] :requested_by_id person_id of the actor (facilitator)
#
class PersonDevelopment::Events::RatingRevisitRequested < RubyEventStore::Event
end
