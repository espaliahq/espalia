# frozen_string_literal: true

# Adds a rater to a draft calibration session. If the person is
# currently in the calibrant population they are moved out of it —
# raters are never calibrated in their own session.
class Operations::CalibrationSessions::AddParticipant < Operations::Base
  include Operations::CalibrationSessions::ScopeChecks

  description "Add a participating rater to a draft calibration session (auto-removes them from the calibrant population if present)."
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
    ensure_people_exist!(:person_id, [ params[:person_id] ])
    ensure_within_facilitator_scope!([ params[:person_id] ], session_facilitator)

    command_handler.add_participant(session.id, params[:person_id], added_by: context.person&.id)

    { session_id: session.id, person_id: params[:person_id] }
  end
end
