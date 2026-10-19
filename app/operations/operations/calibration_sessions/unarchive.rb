# frozen_string_literal: true

# Restores an archived calibration session to the default list. The session
# stays closed. Restoring a closed session that isn't archived changes
# nothing; a live or draft session is refused, as there is nothing to restore.
class Operations::CalibrationSessions::Unarchive < Operations::Base
  include Operations::CalibrationSessions::ScopeChecks

  description "Restore an archived calibration session to the default list (it stays closed). " \
              "Only closed sessions can be archived or restored."
  category :write
  approval :mcp_client

  parameter :session_id, String, required: true

  def policy_check
    authorize session, :unarchive?
  end

  # @return [Hash] `{ session_id, archived }`
  def perform
    command_handler.unarchive_session(session.id, unarchived_by_id: context.person&.id)

    { session_id: session.id, archived: false }
  end
end
