# frozen_string_literal: true

# Event emitted when a live calibration session fires a cell-scoped
# evidence request — the room's "nobody can answer what did you see?"
# outcome (docs/architecture/calibration-sessions.md → §f).
#
# This is PROVENANCE, not the request: the request itself rides the
# existing PersonDevelopment machinery (`EvidenceRequested` on the person's
# stream — hub, reminders, notifications, the response flow). Two streams,
# deliberately not atomic, request leads: a request without session
# provenance is still a valid request; a provenance record pointing at
# nothing is not. Fulfilment is read back from the {EvidenceRequest} read
# model at render time — resolution state is never duplicated here.
#
# @!attribute [r] data
#   @return [Hash] event data
#   @option data [String] :session_id UUID of the calibration session
#   @option data [String] :request_id UUID of the EvidenceRequest this records
#   @option data [String] :person_id UUID of the calibrated person the ask is about
#   @option data [String] :capability_stable_id cross-version capability id
#   @option data [Integer] :level_ordinal the assessed level
#   @option data [String] :requestee_id person_id being asked
#   @option data [String, nil] :message the room's shared reason (also on the request)
#   @option data [String, nil] :requested_by_id person_id of the actor (facilitator)
#
class AssessmentCycles::Events::CalibrationEvidenceRequestRaised < RubyEventStore::Event
end
