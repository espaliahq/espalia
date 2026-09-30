# frozen_string_literal: true

# Closes a declared exploration (ADR-22) with what came of it: `pursue` (work
# towards it), `not_now` (set it aside) or `moved` (the person has moved into
# the role), and an optional note. The other party is notified.
#
# The same people who may declare one, whoever declared it
# ({AssessmentPolicy#close_exploration?}).
#
# Write — :mcp_client approval: it ends an intent, touching no rating.
class Operations::Assessments::CloseExploration < Operations::Base
  include Operations::Assessments::ExplorationPayload

  description "Close an open exploration of another role with its outcome: pursue (work towards it), not_now " \
              "(set it aside) or moved (they have moved into the role), plus an optional note."
  category :write
  approval :mcp_client

  parameter :assignment_id, String, required: true
  parameter :exploration_id, String, required: true
  parameter :outcome, String, required: true, allowed: AssessmentExploration::OUTCOMES
  parameter :note, String

  def policy_check
    authorize assignment, :close_exploration?
  end

  # @return [Hash] the closed exploration (see {ExplorationPayload}) plus
  #   `assignment_id` and `framework_id`
  def perform
    raise ParameterError, "That exploration is already closed" unless exploration.open?

    PersonDevelopment::CommandHandler.new.close_exploration(
      assignment.person_id, assignment.framework_id, exploration.id,
      closed_by_id: context.person&.id, outcome: params[:outcome], note: params[:note].to_s.strip.presence
    )

    { assignment_id: assignment.id, framework_id: assignment.framework_id,
      **exploration_payload(exploration.reload) }
  rescue PersonDevelopment::Aggregate::CommandError => e
    raise ParameterError, e.message
  end

  private

  def assignment
    @assignment ||= PersonFrameworkAssignment.find(params[:assignment_id])
  end

  # @raise [ActiveRecord::RecordNotFound] for an exploration of someone else
  def exploration
    @exploration ||= AssessmentExploration.for_assignment(assignment).find(params[:exploration_id])
  end
end
