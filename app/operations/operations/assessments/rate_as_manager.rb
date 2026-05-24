# frozen_string_literal: true

# Records a manager rating for one capability × level on a direct
# report's assignment. Same input shape and toggle semantics as
# {Operations::Assessments::RateSelf}: same frequency clears, different
# revises, fresh value rates. The policy
# (AssessmentPolicy#create_manager_rating?) refuses the call unless the
# caller is the assessee's manager.
#
# Write — :mcp_client approval. Per the MCP design doc, cross-person
# ratings (manager rating a direct report) are routine enough that the
# MCP client's own write-approval prompt is the right friction; we
# don't push these through the in-app approval flow.
class Operations::Assessments::RateAsManager < Operations::Base
  description "Record or update a manager rating for one of your direct reports' capability × level."
  category :write
  approval :mcp_client

  parameter :assignment_id,        String, required: true
  parameter :capability_stable_id, String, required: true
  parameter :level_ordinal,        Integer, required: true
  parameter :frequency, String, required: true,
                                allowed: %w[none some occasional consistent]
  parameter :comment,   String
  parameter :rationale, String

  def policy_check
    authorize assignment, :create_manager_rating?
  end

  # @return [Hash] same shape as {Operations::Assessments::RateSelf#perform} —
  #   `{ framework_id, capability_stable_id, level_ordinal, cycle_id, frequency }`,
  #   with `frequency` nil on the untoggle path.
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
    existing_freq = existing_rating(cycle_id)&.manager_rated_frequency

    if existing_freq == params[:frequency]
      handler.clear_manager_rating(
        assignment.person_id, assignment.framework_id, params[:capability_stable_id],
        level_ordinal: params[:level_ordinal], cycle_id: cycle_id
      )
    elsif existing_freq.present?
      handler.revise_manager_rating(
        assignment.person_id, assignment.framework_id, params[:capability_stable_id],
        level_ordinal: params[:level_ordinal], frequency: params[:frequency],
        rationale: rationale_for_revision, cycle_id: cycle_id, comment: params[:comment]
      )
    else
      handler.rate_as_manager(
        assignment.person_id, assignment.framework_id, params[:capability_stable_id],
        level_ordinal: params[:level_ordinal], frequency: params[:frequency],
        cycle_id: cycle_id, comment: params[:comment]
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
    existing_rating(cycle_id)&.manager_rated_frequency
  end

  def assignment
    @assignment ||= PersonFrameworkAssignment.find(params[:assignment_id])
  end

  def rationale_for_revision
    return params[:rationale] if params[:rationale].present?

    app_id = AuditMetadata.current[:client_application_id]
    app_id.present? ? "MCP revision (client #{app_id})" : "MCP revision"
  end
end
