# frozen_string_literal: true

# Event emitted when a live calibration session asks a rater to revisit one
# of their manager ratings. VALUE-FREE by design: it carries the room's
# discussion note, never a suggested target rating — notes compose across
# overlapping sessions, target values manufacture contradictions
# (docs/architecture/calibration-sessions.md → "Outcomes").
#
# Mirrored onto the person's PersonDevelopment stream by
# {AssessmentCycles::SyncHandlers::CalibrationRevisitSync} so it surfaces in
# the rater's assessment activity feed where they work.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :session_id UUID of the calibration session
#   @option data [String] :person_id UUID of the calibrated person
#   @option data [String] :capability_stable_id cross-version capability id
#   @option data [Integer] :level_ordinal the rated level
#   @option data [String] :rater_id person_id of the participant who owns the rating
#   @option data [String] :note the room's discussion note (required, value-free)
#   @option data [String, nil] :requested_by_id person_id of the actor (facilitator)
#
class AssessmentCycles::Events::CalibrationRatingRevisitRequested < RubyEventStore::Event
end
