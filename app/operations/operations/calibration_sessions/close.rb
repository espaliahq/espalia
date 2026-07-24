# frozen_string_literal: true

# Closes a calibration session (terminal). Irreversible, so it routes
# through in-app approval when invoked from an MCP client.
class Operations::CalibrationSessions::Close < Operations::Base
  include Operations::CalibrationSessions::ScopeChecks

  description "Close a calibration session (terminal — a closed session becomes the follow-through record)."
  category :write
  approval :in_app

  parameter :session_id, String, required: true

  def policy_check
    authorize session, :close?
  end

  # @return [Hash] `{ session_id, status }`
  def perform
    command_handler.close_session(session.id, closed_by_id: context.person&.id)

    { session_id: session.id, status: "closed" }
  end
end
