# frozen_string_literal: true

# Puts a closed calibration session away: hidden from the default list,
# nothing deleted. Reversible with {Operations::CalibrationSessions::Unarchive},
# so the MCP client's own prompt is friction enough. Archiving an archived
# session changes nothing.
class Operations::CalibrationSessions::Archive < Operations::Base
  include Operations::CalibrationSessions::ScopeChecks

  description "Archive a closed calibration session — hides it from the default list; nothing is deleted " \
              "and calibration_sessions_unarchive restores it."
  category :write
  approval :mcp_client

  parameter :session_id, String, required: true

  def policy_check
    authorize session, :archive?
  end

  # @return [Hash] `{ session_id, archived }`
  def perform
    command_handler.archive_session(session.id, archived_by_id: context.person&.id)

    { session_id: session.id, archived: true }
  end
end
