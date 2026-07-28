# frozen_string_literal: true

# ⚑ Flag an expectation as unclear from a calibration drill-in — raises a
# framework clarification and records the session provenance
# (Operations::CalibrationSessions::FlagExpectation).
class CalibrationSessions::ExpectationFlagsController < ApplicationController
  # POST /calibration_sessions/:calibration_session_id/expectation_flags
  def create
    session_record = CalibrationSession.find(params.expect(:calibration_session_id))
    authorize session_record, :flag_expectation?, policy_class: CalibrationSessionPolicy

    Operations::CalibrationSessions::FlagExpectation.call(
      context: pundit_user,
      params: {
        session_id: session_record.id,
        capability_stable_id: params.expect(:capability_stable_id),
        level_ordinal: params.expect(:level_ordinal).to_i,
        reason: params[:reason].presence
      }
    )

    redirect_to drill_in_path(session_record),
                notice: "Expectation flagged — a clarification discussion is now open on the framework."
  rescue Operations::Base::ParameterError, RuntimeError => e
    redirect_to drill_in_path(session_record), alert: e.message
  rescue ActiveRecord::RecordNotFound
    redirect_to calibration_sessions_path
  end

  private

  # Restores the drill-in's working state (opened person, compare pins) the
  # form passed through — an outcome must not reset the room's screen.
  def drill_in_path(session_record)
    calibration_session_capability_path(
      session_record, params[:capability_stable_id],
      { person: params[:person].presence,
        compare: Array.wrap(params[:compare]).select(&:present?).presence }.compact
    )
  end
end
