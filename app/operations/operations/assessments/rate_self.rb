# frozen_string_literal: true

# Records a self-rating for one capability × level. Mirrors the web
# RatingsController behaviour: setting the same frequency twice clears
# the rating (untoggle), an existing-but-different value is a revise,
# and a fresh value is a new rate.
#
# Write — :mcp_client approval. Users can rate themselves without any
# extra in-app handoff because no permissions or other users are
# affected; the MCP client's own write-approval prompt is the right
# friction.
class Operations::Assessments::RateSelf < Operations::Base
  description "Record or update your own rating for one capability × level."
  category :write
  approval :mcp_client

  parameter :framework_id,         String, required: true
  parameter :capability_stable_id, String, required: true
  parameter :level_ordinal,        Integer, required: true
  parameter :frequency, String, required: true,
                                allowed: %w[none some occasional consistent]
  parameter :comment,   String
  parameter :rationale, String

  def policy_check
    raise Pundit::NotAuthorizedError, "not linked to a person" if context.person.nil?

    authorize assignment, :create_self_rating?
  end

  def perform
    cycle = assignment.current_open_cycle
    raise Operations::Base::ParameterError, "no open assessment cycle" if cycle.nil?

    dispatch(cycle.cycle_id)
    {
      framework_id: params[:framework_id],
      capability_stable_id: params[:capability_stable_id],
      level_ordinal: params[:level_ordinal],
      cycle_id: cycle.cycle_id,
      frequency: resulting_frequency(cycle)
    }
  end

  private

  def dispatch(cycle_id)
    handler = PersonDevelopment::CommandHandler.new
    existing_freq = existing_rating(cycle_id)&.self_rated_frequency

    if existing_freq == params[:frequency]
      handler.clear_self_rating(
        context.person.id, params[:framework_id], params[:capability_stable_id],
        level_ordinal: params[:level_ordinal], cycle_id: cycle_id
      )
    elsif existing_freq.present?
      handler.revise_self_rating(
        context.person.id, params[:framework_id], params[:capability_stable_id],
        level_ordinal: params[:level_ordinal], frequency: params[:frequency],
        rationale: rationale_for_revision, cycle_id: cycle_id, comment: params[:comment]
      )
    else
      handler.rate_self(
        context.person.id, params[:framework_id], params[:capability_stable_id],
        level_ordinal: params[:level_ordinal], frequency: params[:frequency],
        cycle_id: cycle_id, comment: params[:comment]
      )
    end
  end

  def existing_rating(cycle_id)
    AssessmentLevelRating.find_by(
      cycle_id: cycle_id,
      person_id: context.person.id,
      framework_id: params[:framework_id],
      capability_stable_id: params[:capability_stable_id],
      level_ordinal: params[:level_ordinal]
    )
  end

  def resulting_frequency(cycle)
    # Untoggle path returns nil; otherwise the value the caller submitted
    # IS what will be persisted. Re-read once to confirm what the
    # projection settled on.
    existing_rating(cycle.cycle_id)&.self_rated_frequency
  end

  def assignment
    @assignment ||= PersonFrameworkAssignment.find_by!(
      person_id: context.person.id,
      framework_id: params[:framework_id]
    )
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
