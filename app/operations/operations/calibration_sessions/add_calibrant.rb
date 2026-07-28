# frozen_string_literal: true

# Adds a person to a draft calibration session's population — anyone in
# the facilitator's org subtree who isn't a rater in this session.
class Operations::CalibrationSessions::AddCalibrant < Operations::Base
  include Operations::CalibrationSessions::ScopeChecks

  description "Add a person from the facilitator's org to a draft calibration session's population."
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
    ensure_within_facilitator_scope!([ params[:person_id] ], session_facilitator,
                                     framework_id: session.framework_id,
                                     participant_ids: session.participants.pluck(:person_id))

    command_handler.add_calibrant(session.id, params[:person_id], added_by: context.person&.id)

    { session_id: session.id, person_id: params[:person_id] }
  end
end
