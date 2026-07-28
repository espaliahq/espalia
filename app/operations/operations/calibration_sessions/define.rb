# frozen_string_literal: true

# Defines a calibration session in draft state for an assessment cycle.
#
# The caller becomes the session's facilitator. Participants are the
# raters being calibrated with each other (e.g. a department's EMs);
# the calibrant population — typically seeded with the participants'
# reports — is curated further while the session is in draft. The
# population never includes the raters themselves: participants are
# calibrated in a separate session run by their own manager.
class Operations::CalibrationSessions::Define < Operations::Base
  include Operations::CalibrationSessions::ScopeChecks

  description "Define a calibration session (draft) for an assessment cycle. You become the facilitator; seed the participating raters and the calibrant population (typically the participants' reports)."
  category :write
  approval :mcp_client

  parameter :cycle_id, String, required: true
  parameter :name, String, required: true
  parameter :participant_ids, Array, required: true,
            schema: { type: "array", items: { type: "string" }, description: "person_ids of the participating raters" }
  parameter :calibrant_person_ids, Array,
            schema: { type: "array", items: { type: "string" }, description: "person_ids of the people being calibrated — never a participant or the facilitator" }

  def policy_check
    authorize CalibrationSession, :define?
  end

  # @return [Hash] `{ session_id, cycle_id, name, status, participant_ids, calibrant_person_ids }`
  def perform
    validate_inputs!

    session_id = SecureRandom.uuid_v7
    command_handler.define_session(
      session_id, cycle.cycle_id, cycle.framework_id, params[:name],
      cycle.latest_framework_version || cycle.framework_version,
      facilitator_id: context.person.id,
      participant_ids: participant_ids,
      calibrant_person_ids: calibrant_ids,
      defined_by: context.person.id
    )

    {
      session_id: session_id,
      cycle_id: cycle.cycle_id,
      name: params[:name],
      status: "draft",
      participant_ids: participant_ids,
      calibrant_person_ids: calibrant_ids
    }
  end

  private

  def validate_inputs!
    raise ParameterError, "name can't be blank" if params[:name].strip.empty?
    # An empty list also bypasses the per-id scope checks below — and a
    # session without raters seeds nothing; participants are the point.
    raise ParameterError, "participant_ids can't be empty" if participant_ids.empty?

    ensure_uuid!(:cycle_id, params[:cycle_id])
    raise ParameterError, "unknown cycle: #{params[:cycle_id]}" unless cycle
    raise ParameterError, "cycle is closed — calibration sessions need an open cycle" unless cycle.open?

    ensure_people_exist!(:participant_ids, participant_ids)
    ensure_people_exist!(:calibrant_person_ids, calibrant_ids)
    # Calibrants attributed to the participants (delegation-sourced /
    # recorded-manager rows) may legitimately sit outside the live subtree —
    # the server-computed seed must always pass its own validation.
    ensure_within_facilitator_scope!(participant_ids + calibrant_ids, context.person,
                                     framework_id: cycle.framework_id,
                                     participant_ids: participant_ids)

    overlap = calibrant_ids & (participant_ids + [ context.person.id ])
    return if overlap.empty?

    raise ParameterError,
          "calibrant_person_ids can't include session raters: #{overlap.join(', ')}"
  end

  def cycle
    @cycle ||= AssessmentCycle.find_by(cycle_id: params[:cycle_id])
  end

  def participant_ids
    @participant_ids ||= ensure_uuid_list!(:participant_ids, params[:participant_ids]).uniq
  end

  def calibrant_ids
    @calibrant_ids ||= ensure_uuid_list!(:calibrant_person_ids, params[:calibrant_person_ids]).uniq
  end
end
