# frozen_string_literal: true

# Starts a calibration session, freezing its participants and
# population (event-carried snapshots). Locking the room is what makes
# every divergence number on screen stable for the whole discussion, so
# it routes through in-app approval when invoked from an MCP client.
class Operations::CalibrationSessions::Start < Operations::Base
  include Operations::CalibrationSessions::ScopeChecks

  description "Start a calibration session — freezes the participants and the calibrant population."
  category :write
  approval :in_app

  parameter :session_id, String, required: true

  def policy_check
    authorize session, :start?
  end

  # @return [Hash] `{ session_id, status }`
  def perform
    command_handler.start_session(session.id, started_by_id: context.person&.id)

    { session_id: session.id, status: "started" }
  end
end
