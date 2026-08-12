# frozen_string_literal: true

# ⚑ Flag one example (role illustration) as unclear from a calibration
# drill-in — raises an illustration-anchored framework clarification and
# records the session provenance
# (Operations::CalibrationSessions::FlagIllustration).
class CalibrationSessions::IllustrationFlagsController < ApplicationController
  include CalibrationSessions::DrillInReturnPath

  # POST /calibration_sessions/:calibration_session_id/illustration_flags
  def create
    session_record = CalibrationSession.find(params.expect(:calibration_session_id))
    authorize session_record, :flag_expectation?, policy_class: CalibrationSessionPolicy

    Operations::CalibrationSessions::FlagIllustration.call(
      context: pundit_user,
      params: {
        session_id: session_record.id,
        illustration_id: params.expect(:illustration_id),
        reason: params[:reason].presence
      }
    )

    # `activity=open` — the flag lands somewhere visible even with the log
    # panel closed (the expectation flag's rule).
    redirect_to drill_in_return_path(session_record, person_id: params[:person],
                                     extra: { activity: "open" }),
                notice: "Example flagged — a clarification discussion is now open on the framework."
  rescue Operations::Base::ParameterError, RuntimeError => e
    redirect_to drill_in_return_path(session_record, person_id: params[:person]), alert: e.message
  rescue ActiveRecord::RecordNotFound
    redirect_to calibration_sessions_path
  end
end
