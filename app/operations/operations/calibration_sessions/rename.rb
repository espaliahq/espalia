# frozen_string_literal: true

# Renames a calibration session, in any status — a name is a label, not a
# fact the room argued over. Whitespace is stripped; an unchanged name writes
# nothing. The session log keeps the old name ("Renamed to … (was …)").
class Operations::CalibrationSessions::Rename < Operations::Base
  include Operations::CalibrationSessions::ScopeChecks

  description "Rename a calibration session (any status; the session log records the previous name)."
  category :write
  approval :mcp_client

  parameter :session_id, String, required: true
  parameter :name,       String, required: true, allow_blank: false

  def policy_check
    authorize session, :rename?
  end

  # @return [Hash] `{ session_id, name }` — the name as applied (stripped)
  def perform
    command_handler.rename_session(session.id, params[:name], renamed_by_id: context.person&.id)

    { session_id: session.id, name: session.reload.name }
  end
end
