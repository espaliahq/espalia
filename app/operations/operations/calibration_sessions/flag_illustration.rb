# frozen_string_literal: true

# Flags ONE example (role illustration) as unclear from a live calibration
# session — the room's "this example is what misleads raters" outcome,
# narrower than flagging the cell's expectation text.
#
# Raises a framework **clarification** anchored on the illustration (the
# same non-proposal suggestion kind expectation flags use — same lifecycle,
# thread, and feed rails), then records the session provenance with the
# illustration id, so the expectation flag and each example's flag are
# independent one-per-session outcomes.
#
# Authorized as the session facilitator (or tenant admin) — the flag is
# raised on the session's authority, independent of collaborator roles.
class Operations::CalibrationSessions::FlagIllustration < Operations::Base
  include Operations::CalibrationSessions::ScopeChecks

  description "Flag one example (role illustration) as unclear from a live calibration session — raises a framework clarification anchored on the example."
  category :write
  approval :mcp_client

  parameter :session_id, String, required: true
  parameter :illustration_id, String, required: true
  # The room's note on what misleads (folded into the clarification's
  # rationale after the session-context prefix).
  parameter :reason, String

  def policy_check
    authorize session, :flag_expectation?
  end

  # @return [Hash] `{ session_id, suggestion_id, illustration_id, capability_stable_id, level_ordinal }`
  def perform
    ensure_uuid!(:illustration_id, params[:illustration_id])
    ensure_session_started!
    require_author!
    illustration # 404s early when the id isn't in the session's framework
    ensure_example_unflagged!

    suggestion_id = SecureRandom.uuid_v7
    begin
      Frameworks::CommandHandler.new.request_clarification(
        session.framework_id, suggestion_id, "role_illustration", params[:illustration_id],
        author_id: context.person&.id&.to_s,
        level_ordinal: level_ordinal,
        rationale: composed_rationale
      )

      command_handler.flag_expectation(
        session.id,
        capability_stable_id: capability_stable_id,
        level_ordinal: level_ordinal,
        illustration_id: params[:illustration_id],
        suggestion_id: suggestion_id,
        flagged_by_id: context.person&.id,
        reason: params[:reason].presence
      )
    rescue RuntimeError => e
      # Aggregate refusals (a concurrent flag winning the pre-check race,
      # session lifecycle changes mid-request) are client-state problems —
      # classify as invalid params (-32602 / flash), never a 500/-32603.
      raise Operations::Base::ParameterError, e.message
    end

    {
      session_id: session.id,
      suggestion_id: suggestion_id,
      illustration_id: params[:illustration_id],
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal
    }
  end

  private

  def ensure_session_started!
    return if session.started?

    raise Operations::Base::ParameterError,
          "session is #{session.status} — examples are flagged from a live session"
  end

  # The clarification's author is a first-class domain fact
  # (framework_suggested_edits.author_id is NOT NULL) — see FlagExpectation.
  def require_author!
    return if context.person.present?

    raise Operations::Base::ParameterError,
          "Flagging an example requires a linked person; this account has none."
  end

  # One flag per example per session (the aggregate re-checks serialized
  # against the stream; this is the friendly pre-check).
  def ensure_example_unflagged!
    already = CalibrationSessions::SessionOutcomes.new(session: session).flags
      .any? { |f| f[:illustration_id] == params[:illustration_id] }
    return unless already

    raise Operations::Base::ParameterError,
          "this example was already flagged in this session — the discussion lives on the framework clarification"
  end

  def composed_rationale
    prefix = "Flagged during #{session.name} calibration (example under #{capability.name} · L#{level_ordinal})"
    reason = params[:reason].to_s.strip
    reason.present? ? "#{prefix}: #{reason}" : "#{prefix} — raters read this example inconsistently."
  end

  # The illustration in the session's framework — scoped through the
  # expectation → capability → category chain so a foreign framework's id
  # 404s instead of minting a clarification the session can't render.
  def illustration
    @illustration ||= FrameworkState::RoleIllustration
      .joins(expectation: { capability: :category })
      .where(framework_capability_categories: { framework_id: session.framework_id })
      .find_by!(illustration_id: params[:illustration_id])
  end

  def expectation
    @expectation ||= illustration.expectation
  end

  def level_ordinal
    expectation.level_ordinal
  end

  def capability
    @capability ||= expectation.capability
  end

  def capability_stable_id
    capability.stable_id
  end
end
