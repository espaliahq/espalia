# frozen_string_literal: true

# Puts a closed calibration session away — hidden from the default list,
# nothing deleted. Reversed by {CalibrationSessions::UnarchivesController}.
class CalibrationSessions::ArchivesController < ApplicationController
  # POST /calibration_sessions/:id/archive
  def create
    session_record = CalibrationSession.find(params.expect(:id))
    authorize session_record, :archive?

    Operations::CalibrationSessions::Archive.call(
      context: pundit_user, params: { session_id: session_record.id }
    )
    redirect_back_or_to calibration_sessions_path,
                        notice: "“#{session_record.name}” archived. Show archived sessions to find it again."
  rescue ActiveRecord::RecordNotFound
    redirect_to calibration_sessions_path
  rescue Operations::Base::ParameterError, RuntimeError => e
    redirect_back_or_to calibration_sessions_path, alert: e.message
  end
end
