# frozen_string_literal: true

# Records a free-text minute on a live calibration session — the room's
# narrative ("add X to the org-wide session", "revisit the L4 wording next
# cycle"), optionally anchored to a capability or a calibrant. Surfaces in
# the session log on the session page (the follow-through artifact).
class Operations::CalibrationSessions::RecordNote < Operations::Base
  include Operations::CalibrationSessions::ScopeChecks

  description "Record a free-text minute on a live calibration session, optionally anchored to a capability or person. " + Prose::MCP_NOTE
  category :write
  approval :mcp_client

  parameter :session_id, String, required: true
  parameter :body, String, required: true
  parameter :capability_stable_id, String
  parameter :person_id, String

  def policy_check
    authorize session, :flag_expectation?
  end

  # @return [Hash] `{ session_id }`
  def perform
    ensure_body!
    ensure_uuid!(:capability_stable_id, params[:capability_stable_id]) if params[:capability_stable_id].present?
    ensure_uuid!(:person_id, params[:person_id]) if params[:person_id].present?
    ensure_session_started!

    command_handler.record_note(
      session.id,
      body: params[:body],
      capability_stable_id: params[:capability_stable_id].presence,
      person_id: params[:person_id].presence,
      recorded_by_id: context.person&.id
    )

    { session_id: session.id }
  end

  private

  def ensure_body!
    return if params[:body].strip.present?

    raise Operations::Base::ParameterError, "body can't be blank"
  end

  def ensure_session_started!
    return if session.started?

    raise Operations::Base::ParameterError,
          "session is #{session.status} — notes are recorded from a live session"
  end
end
