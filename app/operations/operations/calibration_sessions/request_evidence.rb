# frozen_string_literal: true

# Fires a cell-scoped evidence request from a live calibration session —
# §f: when a disputed cell is unbacked and the room can't answer "what did
# you see?", the resolution IS an evidence request.
#
# The request rides the existing PersonDevelopment machinery verbatim
# (`request_evidence` → hub, reminders, requestee notification, the
# response flow — nothing new); the session then records
# `CalibrationEvidenceRequestRaised` on its own stream so the
# follow-through page can track it. Two streams, deliberately not atomic,
# request leads — a request without provenance is still a valid request; a
# provenance record pointing at nothing is not (the flag → clarification
# shape).
#
# TWO authorization bars, both enforced here: the session's facilitator
# bar (`flag_expectation?` — outcomes are raised on the session's
# authority) AND the per-person `EvidenceRequestPolicy#request?` the
# assessment surface enforces. The second is not redundant: ScopeChecks'
# delegation exemption means the population can contain someone the
# facilitator holds no assessment entitlement for, and the session must
# not become a way to fire requests about them.
class Operations::CalibrationSessions::RequestEvidence < Operations::Base
  include Operations::CalibrationSessions::ScopeChecks

  description "Ask a colleague for feedback / evidence on a capability × level from a live calibration session."
  category :write
  approval :mcp_client

  parameter :session_id, String, required: true
  parameter :person_id, String, required: true
  parameter :requestee_person_id, String, required: true
  parameter :capability_stable_id, String, required: true
  parameter :level_ordinal, Integer, required: true
  # One shared reason the requestee sees — optional, but a bare ask lands
  # colder than "the room couldn't answer what good looks like here".
  parameter :message, String
  parameter :due_at, String

  def policy_check
    raise Pundit::NotAuthorizedError, "not linked to a person" if context.person.nil?

    authorize session, :flag_expectation?
    authorize assignment, :request?, policy_class: EvidenceRequestPolicy
  end

  # @return [Hash] `{ session_id, request_id, person_id, requestee_person_id,
  #   capability_stable_id, level_ordinal, status }`
  def perform
    ensure_uuid!(:person_id, params[:person_id])
    ensure_uuid!(:requestee_person_id, params[:requestee_person_id])
    ensure_uuid!(:capability_stable_id, params[:capability_stable_id])
    ensure_session_started!
    ensure_requestee!
    ensure_capability_in_framework!
    ensure_not_already_pending!

    request_id = SecureRandom.uuid_v7
    begin
      # Request first (it must exist before provenance can point at it);
      # same command the assessment surface dispatches, so the requestee's
      # notification, the hub card, and the reminder sweep all come along.
      PersonDevelopment::CommandHandler.new.request_evidence(
        params[:person_id], session.framework_id, request_id,
        requested_by_id: context.person.id,
        requestee_person_id: params[:requestee_person_id],
        capability_stable_id: params[:capability_stable_id],
        level_ordinal: params[:level_ordinal],
        message: params[:message].presence,
        due_at: params[:due_at].presence
      )

      command_handler.raise_evidence_request(
        session.id,
        request_id: request_id,
        person_id: params[:person_id],
        capability_stable_id: params[:capability_stable_id],
        level_ordinal: params[:level_ordinal],
        requestee_id: params[:requestee_person_id],
        message: params[:message].presence,
        requested_by_id: context.person.id
      )
    rescue PersonDevelopment::Aggregate::CommandError, RuntimeError => e
      # Aggregate refusals (a duplicate pending ask on the cell, session
      # lifecycle changes mid-request) are client-state problems — invalid
      # params (-32602 / flash), never a 500/-32603.
      raise Operations::Base::ParameterError, e.message
    end

    {
      session_id: session.id,
      request_id: request_id,
      person_id: params[:person_id],
      requestee_person_id: params[:requestee_person_id],
      capability_stable_id: params[:capability_stable_id],
      level_ordinal: params[:level_ordinal],
      status: EvidenceRequest.find_by(id: request_id)&.status
    }
  end

  private

  def ensure_session_started!
    return if session.started?

    raise Operations::Base::ParameterError,
          "session is #{session.status} — evidence requests are fired from a live session"
  end

  def ensure_calibrant!
    in_population = CalibrationSessionMember.calibrants
      .where(session_id: session.id, person_id: params[:person_id]).exists?
    return if in_population

    raise Operations::Base::ParameterError, "person is not in this session's population"
  end

  def ensure_requestee!
    requestee = Person.find_by(id: params[:requestee_person_id], status: "active")
    if requestee.nil?
      raise Operations::Base::ParameterError,
            "requestee_person_id is not an active person in this workspace"
    end
    # The assessee may be asked (nudged for more evidence); only asking
    # yourself is meaningless — the assessment surface's rule verbatim.
    return unless requestee.id == context.person.id

    raise Operations::Base::ParameterError, "cannot request evidence from yourself"
  end

  # The assessment surface greys out a requestee with a pending ask on this
  # exact cell rather than re-asking; the domain deliberately allows
  # parallel requests, so the friendly block lives here — same rule, same
  # wording surface (RequestCandidates#already_requested).
  def ensure_not_already_pending!
    pending = EvidenceRequest.where(
      person_id: params[:person_id],
      requestee_person_id: params[:requestee_person_id],
      capability_stable_id: params[:capability_stable_id],
      level_ordinal: params[:level_ordinal],
      status: "pending"
    ).exists?
    return unless pending

    raise Operations::Base::ParameterError,
          "they already have a pending request on this behaviour — nudge that one instead"
  end

  def ensure_capability_in_framework!
    in_framework = FrameworkState::Capability
      .joins(:category)
      .where(stable_id: params[:capability_stable_id])
      .merge(FrameworkState::CapabilityCategory.where(framework_id: session.framework_id))
      .exists?
    return if in_framework

    raise Operations::Base::ParameterError,
          "capability_stable_id does not belong to the session's framework"
  end

  # The per-person entitlement anchor — the same record the assessment
  # surface authorizes requests against. Resolved in policy_check, so the
  # population gate runs first: "not in the population" is the precise
  # refusal for an outsider, whether or not they hold an assignment.
  def assignment
    @assignment ||= begin
      ensure_calibrant!
      PersonFrameworkAssignment
        .find_by(person_id: params[:person_id], framework_id: session.framework_id) ||
        raise(Operations::Base::ParameterError,
              "person has no assignment on this session's framework")
    end
  end
end
