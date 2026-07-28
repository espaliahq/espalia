# frozen_string_literal: true

# Add / remove people from a draft calibration session's population.
# Dispatches through the shared Operations::CalibrationSessions classes.
class CalibrationSessions::CalibrantsController < ApplicationController
  before_action :set_session

  # POST /calibration_sessions/:calibration_session_id/calibrants
  def create
    authorize @session, :curate?
    Operations::CalibrationSessions::AddCalibrant.call(
      context: pundit_user,
      params: { session_id: @session.id, person_id: params.expect(:person_id) }
    )
    redirect_to calibration_session_path(@session), notice: "Added to the population."
  rescue Operations::Base::ParameterError, RuntimeError => e
    redirect_to calibration_session_path(@session), alert: e.message
  end

  # DELETE /calibration_sessions/:calibration_session_id/calibrants/:id
  def destroy
    authorize @session, :curate?
    Operations::CalibrationSessions::RemoveCalibrant.call(
      context: pundit_user,
      params: { session_id: @session.id, person_id: params.expect(:id) }
    )
    redirect_to calibration_session_path(@session), status: :see_other, notice: "Removed from the population."
  rescue Operations::Base::ParameterError, RuntimeError => e
    redirect_to calibration_session_path(@session), status: :see_other, alert: e.message
  end

  private

  def set_session
    @session = CalibrationSession.find(params.expect(:calibration_session_id))
  rescue ActiveRecord::RecordNotFound
    redirect_to calibration_sessions_path
  end
end
