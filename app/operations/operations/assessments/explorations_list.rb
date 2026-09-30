# frozen_string_literal: true

# Lists one assessment's declared explorations (ADR-22), newest first —
# open ones, closed ones with their outcome, or both. Read-only; anyone who
# may view the assessment ({AssessmentPolicy#show?}).
class Operations::Assessments::ExplorationsList < Operations::Base
  include Operations::Assessments::ExplorationPayload

  description "List the explorations of other roles or levels declared on one assessment, newest first, with " \
              "who declared them and, once closed, the outcome. Each carries the lens params that read the " \
              "assessment against its target."
  category :read
  approval :none

  STATUS_FILTERS = %w[open closed all].freeze

  parameter :assignment_id, String, required: true
  parameter :status, String, allowed: STATUS_FILTERS

  def policy_check
    authorize assignment, :show?
  end

  # @return [Hash] `{ assignment_id, framework_id, explorations: [...] }`
  def perform
    scope = AssessmentExploration.for_assignment(assignment).includes(:target_role, :started_by, :closed_by)
      .order(started_at: :desc)
    scope = scope.where(status: params[:status]) if %w[open closed].include?(params[:status])

    { assignment_id: assignment.id, framework_id: assignment.framework_id,
      explorations: scope.map { |exploration| exploration_payload(exploration) } }
  end

  private

  def assignment
    @assignment ||= PersonFrameworkAssignment.find(params[:assignment_id])
  end
end
