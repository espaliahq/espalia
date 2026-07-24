# frozen_string_literal: true

# Removes a rater from a draft calibration session. Their reports stay
# in the calibrant population — the population is a curated list, and
# people whose rater isn't in the room remain valid reference points.
class Operations::CalibrationSessions::RemoveParticipant < Operations::Base
  include Operations::CalibrationSessions::ScopeChecks

  description "Remove a participating rater from a draft calibration session (their reports stay in the population)."
  category :write
  approval :mcp_client

  parameter :session_id, String, required: true
  parameter :person_id, String, required: true

  def policy_check
    authorize session, :curate?
  end

  # @return [Hash] `{ session_id, person_id }`
  def perform
    ensure_uuid!(:person_id, params[:person_id])

    command_handler.remove_participant(session.id, params[:person_id], removed_by: context.person&.id)

    { session_id: session.id, person_id: params[:person_id] }
  end
end
