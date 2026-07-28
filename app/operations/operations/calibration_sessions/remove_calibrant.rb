# frozen_string_literal: true

# Removes a person from a draft calibration session's population.
class Operations::CalibrationSessions::RemoveCalibrant < Operations::Base
  include Operations::CalibrationSessions::ScopeChecks

  description "Remove a person from a draft calibration session's population."
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

    command_handler.remove_calibrant(session.id, params[:person_id], removed_by: context.person&.id)

    { session_id: session.id, person_id: params[:person_id] }
  end
end
