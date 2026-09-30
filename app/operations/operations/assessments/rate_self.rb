# frozen_string_literal: true

# Records a self-rating for one capability × level on the named
# assignment. Mirrors the web RatingsController behaviour: on a
# carried-forward (seeded) value, re-sending the same frequency CONFIRMS
# it as a human rating; on a human value it clears (untoggle); an
# existing-but-different value is a revise, a fresh value is a new rate,
# and `clear: true` clears explicitly (or no-ops when already empty).
#
# Write — :mcp_client approval. Users can rate themselves without any
# extra in-app handoff because no permissions or other users are
# affected; the MCP client's own write-approval prompt is the right
# friction.
#
# Input shape is shared with {Operations::Assessments::RateAsManager}
# and {Operations::Assessments::Align}: all three take `assignment_id`
# (uniformly identifying whose assessment is being touched) plus the
# capability/level/frequency triple, and an optional `as_role_id` naming
# the role the rater was reading the cell through (ADR-22). The cell must
# be one that role reads. Pundit decides who can do what.
class Operations::Assessments::RateSelf < Operations::Base
  include Operations::Assessments::RatingCell

  description "Record or update your own rating for one capability × level. Pass as_role_id to rate a cell " \
              "another role in the framework reads (a role lens): the rating is the same fact about you " \
              "at that capability × level, and counts wherever a role reads the cell."
  category :write
  approval :mcp_client

  parameter :assignment_id,        String, required: true
  parameter :capability_stable_id, String, required: true
  parameter :level_ordinal,        Integer, required: true
  parameter :frequency, String, required: true,
                                allowed: %w[none some occasional consistent]
  parameter :comment,   String
  parameter :rationale, String
  # Explicit clear (no-op if already empty). Without it, re-sending the
  # current frequency confirms a carried value or untoggle-clears a human
  # one — so a client that MEANS clear should say so.
  parameter :clear, :boolean
  # The role whose cells the rater is reading; blank = the home role.
  parameter :as_role_id, String

  def policy_check
    authorize assignment, :create_self_rating?
    rating_lens
  end

  # @return [Boolean] false when the call changed nothing (an explicit clear
  #   of an empty rating) — the web then announces nothing
  def changed? = @changed != false

  # @return [Hash] uniform rating-tool payload —
  #   `{ framework_id, capability_stable_id, level_ordinal, cycle_id, frequency }`.
  #   `frequency` is nil on the untoggle path (rating cleared), otherwise the
  #   value the projection settled on (always equal to `params[:frequency]`
  #   for rate/revise paths).
  def perform
    cycle = assignment.current_open_cycle
    raise Operations::Base::ParameterError, "no open assessment cycle" if cycle.nil?

    dispatch(cycle.cycle_id)
    {
      framework_id: assignment.framework_id,
      capability_stable_id: params[:capability_stable_id],
      level_ordinal: params[:level_ordinal],
      cycle_id: cycle.cycle_id,
      frequency: resulting_frequency(cycle.cycle_id)
    }
  end

  private

  def dispatch(cycle_id)
    handler = PersonDevelopment::CommandHandler.new
    existing = existing_rating(cycle_id)
    existing_freq = existing&.self_rated_frequency

    if params[:clear].present?
      # Explicit clear-or-noop — mirrors the web's rating[clear] marker.
      return @changed = false if existing_freq.blank?

      handler.clear_self_rating(
        assignment.person_id, assignment.framework_id, params[:capability_stable_id],
        level_ordinal: params[:level_ordinal], cycle_id: cycle_id
      )
    elsif existing_freq == params[:frequency] && existing&.self_rating_carried?
      # Confirming a carried-forward (seeded) value — same gesture as the
      # web: re-emit as human so the provenance flips.
      handler.revise_self_rating(
        assignment.person_id, assignment.framework_id, params[:capability_stable_id],
        level_ordinal: params[:level_ordinal], frequency: params[:frequency],
        rationale: "Confirmed carried-forward rating", cycle_id: cycle_id,
        # Confirm without a comment keeps the existing one (typically the
        # seeded-provenance note) rather than wiping it.
        comment: params[:comment].presence || existing.self_rated_comment,
        via_role_id: via_role_id
      )
    elsif existing_freq == params[:frequency]
      handler.clear_self_rating(
        assignment.person_id, assignment.framework_id, params[:capability_stable_id],
        level_ordinal: params[:level_ordinal], cycle_id: cycle_id
      )
    elsif existing_freq.present?
      handler.revise_self_rating(
        assignment.person_id, assignment.framework_id, params[:capability_stable_id],
        level_ordinal: params[:level_ordinal], frequency: params[:frequency],
        rationale: rationale_for_revision, cycle_id: cycle_id, comment: params[:comment],
        via_role_id: via_role_id
      )
    else
      handler.rate_self(
        assignment.person_id, assignment.framework_id, params[:capability_stable_id],
        level_ordinal: params[:level_ordinal], frequency: params[:frequency],
        cycle_id: cycle_id, comment: params[:comment],
        via_role_id: via_role_id
      )
    end
  end

  def existing_rating(cycle_id)
    AssessmentLevelRating.find_by(
      cycle_id: cycle_id,
      person_id: assignment.person_id,
      framework_id: assignment.framework_id,
      capability_stable_id: params[:capability_stable_id],
      level_ordinal: params[:level_ordinal]
    )
  end

  def resulting_frequency(cycle_id)
    # Untoggle path returns nil; otherwise the value the caller submitted
    # IS what will be persisted. Re-read once to confirm what the
    # projection settled on.
    existing_rating(cycle_id)&.self_rated_frequency
  end

  def assignment
    @assignment ||= PersonFrameworkAssignment.find(params[:assignment_id])
  end

  # Caller-supplied rationale wins; otherwise we record a value specific
  # enough to be useful in the activity log (which client_application_id
  # the revision came from) without being a generic placeholder.
  def rationale_for_revision
    return params[:rationale] if params[:rationale].present?

    app_id = AuditMetadata.current[:client_application_id]
    app_id.present? ? "MCP revision (client #{app_id})" : "MCP revision"
  end
end
