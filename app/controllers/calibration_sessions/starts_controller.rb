# frozen_string_literal: true

# Starts a calibration session — freezes participants and population.
class CalibrationSessions::StartsController < ApplicationController
  # POST /calibration_sessions/:id/start
  def create
    session_record = CalibrationSession.find(params.expect(:id))
    authorize session_record, :start?

    Operations::CalibrationSessions::Start.call(
      context: pundit_user, params: { session_id: session_record.id }
    )
    redirect_to calibration_session_path(session_record), notice: "Session started — participants and population are now frozen."
  rescue ActiveRecord::RecordNotFound
    redirect_to calibration_sessions_path
  rescue Operations::Base::ParameterError, RuntimeError => e
    redirect_to calibration_session_path(params[:id]), alert: e.message
  end
end
