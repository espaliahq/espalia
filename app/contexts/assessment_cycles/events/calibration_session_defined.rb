# frozen_string_literal: true

# Event emitted when a calibration session is defined.
#
# The first event in the CalibrationSession stream. A session is a
# facilitator-run forum for comparing how a set of participant raters
# rate their reports (the calibrants) against the framework's
# behavioural expectations. The cycle_id is a reference, not stream
# co-location — see docs/architecture/calibration-sessions.md.
#
# The seeded calibrant list is curated (add/remove) while the session
# is in draft; participants and calibrants are frozen at start.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :session_id UUID of the calibration session
#   @option data [String] :cycle_id UUID of the assessment cycle this session calibrates within
#   @option data [String] :framework_id UUID of the framework
#   @option data [Integer] :framework_version framework version snapshot at define time
#   @option data [String] :name display name (e.g. "Engineering calibration")
#   @option data [String] :facilitator_id person_id of the facilitator (the only
#     viewer in v1 — see the facilitator-only access model)
#   @option data [Array<String>] :participant_ids person_ids of the participating raters
#   @option data [Array<String>] :calibrant_person_ids seeded population — the people
#     whose ratings are calibrated. Never intersects participants ∪ {facilitator}.
#   @option data [String, nil] :defined_by person_id of the creator
#
class AssessmentCycles::Events::CalibrationSessionDefined < RubyEventStore::Event
end
