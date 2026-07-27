# frozen_string_literal: true

# Flags a capability × level expectation as unclear from a live calibration
# session — the room's "this text is the problem" outcome.
#
# The flag raises a framework **clarification** (a non-proposal suggestion —
# see docs/architecture/calibration-sessions.md → "The clarification kind")
# with an auto-composed rationale carrying the session context, then records
# `CalibrationExpectationFlagged` on the session stream with the resulting
# suggestion_id so the follow-through page can track the discussion's status.
# Two streams, deliberately not atomic — the framework write leads (a
# clarification without session provenance is still a valid clarification;
# a provenance record pointing at nothing is not).
#
# Authorized as the session facilitator (or tenant admin) — deliberately
# independent of framework collaborator roles: the flag is raised on the
# session's authority.
class Operations::CalibrationSessions::FlagExpectation < Operations::Base
  include Operations::CalibrationSessions::ScopeChecks

  description "Flag a capability × level expectation as unclear from a live calibration session — raises a framework clarification."
  category :write
  approval :mcp_client

  parameter :session_id, String, required: true
  parameter :capability_stable_id, String, required: true
  parameter :level_ordinal, Integer, required: true
  # The room's note on what is unclear (folded into the clarification's
  # rationale after the session-context prefix).
  parameter :reason, String

  def policy_check
    authorize session, :flag_expectation?
  end

  # @return [Hash] `{ session_id, suggestion_id, capability_stable_id, level_ordinal, target_entity_type }`
  def perform
    ensure_uuid!(:capability_stable_id, params[:capability_stable_id])
    ensure_session_started!
    ensure_cell_unflagged!
    capability # 404s early when the stable_id isn't in the session's framework

    suggestion_id = SecureRandom.uuid_v7
    Frameworks::CommandHandler.new.request_clarification(
      session.framework_id, suggestion_id, anchor_type, anchor_id,
      author_id: context.person&.id&.to_s,
      level_ordinal: params[:level_ordinal],
      rationale: composed_rationale
    )

    command_handler.flag_expectation(
      session.id,
      capability_stable_id: params[:capability_stable_id],
      level_ordinal: params[:level_ordinal],
      suggestion_id: suggestion_id,
      flagged_by_id: context.person&.id,
      reason: params[:reason].presence
    )

    {
      session_id: session.id,
      suggestion_id: suggestion_id,
      capability_stable_id: params[:capability_stable_id],
      level_ordinal: params[:level_ordinal],
      target_entity_type: anchor_type
    }
  end

  private

  def ensure_session_started!
    return if session.started?

    raise Operations::Base::ParameterError,
          "session is #{session.status} — expectations are flagged from a live session"
  end

  # One flag per cell per session (the aggregate re-checks serialized against
  # the stream; this is the friendly pre-check).
  def ensure_cell_unflagged!
    already = CalibrationSessions::SessionOutcomes.new(session: session).flags
      .any? { |f| f[:capability_stable_id] == params[:capability_stable_id] && f[:level_ordinal] == params[:level_ordinal] }
    return unless already

    raise Operations::Base::ParameterError,
          "this cell was already flagged in this session — the discussion lives on the framework clarification"
  end

  # "Flagged during «name» calibration" + the room's note when given — the
  # clarification's question, readable on the framework side without any
  # calibration context.
  def composed_rationale
    prefix = "Flagged during #{session.name} calibration"
    reason = params[:reason].to_s.strip
    reason.present? ? "#{prefix}: #{reason}" : "#{prefix} — raters read this expectation inconsistently."
  end

  def anchor_type
    expectation ? "behavioural_expectation" : "capability"
  end

  def anchor_id
    expectation ? expectation.expectation_id : capability.capability_id
  end

  # The cell's expectation in the session's framework, if defined. Calibration
  # rates the published version, so the read model is the right source.
  def expectation
    return @expectation if defined?(@expectation)

    @expectation = FrameworkState::BehaviouralExpectation.find_by(
      capability_id: capability.capability_id, level_ordinal: params[:level_ordinal]
    )
  end

  def capability
    @capability ||= FrameworkState::Capability
      .joins(:category)
      .where(framework_capability_categories: { framework_id: session.framework_id })
      .find_by!(stable_id: params[:capability_stable_id])
  end
end
