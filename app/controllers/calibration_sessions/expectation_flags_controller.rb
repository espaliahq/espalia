# frozen_string_literal: true

# ⚑ Flag an expectation as unclear from a calibration drill-in — raises a
# framework clarification and records the session provenance
# (Operations::CalibrationSessions::FlagExpectation).
class CalibrationSessions::ExpectationFlagsController < ApplicationController
  include CalibrationSessions::DrillInReturnPath

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

    # `activity=open` so the flag lands somewhere visible even if the room
    # had the log panel closed — same rule the note composer follows. Only
    # on success: a failed flag records nothing for the panel to show.
    redirect_to drill_in_return_path(session_record, person_id: params[:person],
                                     extra: { activity: "open" }),
                notice: "Expectation flagged — a clarification discussion is now open on the framework."
  rescue Operations::Base::ParameterError, RuntimeError => e
    redirect_to drill_in_return_path(session_record, person_id: params[:person]), alert: e.message
  rescue ActiveRecord::RecordNotFound
    redirect_to calibration_sessions_path
  end
end
