# frozen_string_literal: true

# Grant / revoke manager-rating delegations for an assessment.
#
# A delegation lets someone other than the reporting manager record manager
# ratings for a report (e.g. when the report is seconded into another team).
# Granting is restricted to ancestor managers or tenant admins — see
# {AssessmentPolicy#delegate_manager_rating?}. Both actions dispatch through
# the shared {Operations::Assessments} classes so web and MCP behave identically.
#
class Assessments::DelegationsController < ApplicationController
  before_action :require_person
  before_action :set_assignment

  # POST /assessments/:assessment_id/delegations
  def create
    authorize @assignment, :delegate_manager_rating?

    Operations::Assessments::DelegateManagerRating.call(
      context: pundit_user,
      params: {
        assignment_id: @assignment.id,
        delegate_person_id: params.expect(delegation: [ :delegate_person_id, :expires_at, :reason ])[:delegate_person_id],
        expires_at: params.dig(:delegation, :expires_at),
        reason: params.dig(:delegation, :reason)
      }
    )
    render_frame
  rescue Operations::Base::ParameterError, PersonDevelopment::Aggregate::CommandError,
         ActiveRecord::RecordNotFound => e
    render_frame(error: e.message)
  end

  # DELETE /assessments/:assessment_id/delegations/:id
  def destroy
    authorize @assignment, :revoke_manager_rating_delegation?
    delegation = active_delegations.find(params.expect(:id))

    Operations::Assessments::RevokeManagerRatingDelegation.call(
      context: pundit_user,
      params: { assignment_id: @assignment.id, delegate_person_id: delegation.delegate_person_id }
    )
    render_frame
  rescue Operations::Base::ParameterError, PersonDevelopment::Aggregate::CommandError,
         ActiveRecord::RecordNotFound => e
    render_frame(error: e.message)
  end

  private

  def require_person
    head :forbidden unless current_person
  end

  def set_assignment
    return unless current_person

    @assignment = PersonFrameworkAssignment.find(params.expect(:assessment_id))
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  # Re-renders just the `delegations-list` Turbo Frame so grant/revoke update
  # in place inside the open modal.
  def render_frame(error: nil)
    render Views::Assessments::Delegations::Frame.new(
      assignment: @assignment,
      active_delegations: active_delegations.includes(:delegate).to_a,
      candidate_delegates: candidate_delegates,
      error: error
    )
  end

  def active_delegations
    ManagerAssessmentDelegation.active.for_assignment(@assignment)
  end

  def candidate_delegates
    ManagerAssessmentDelegation.candidate_people(
      assignment: @assignment, actor_person_id: current_person.id
    )
  end

  def user_not_authorized(_exception = nil)
    head :forbidden
  end
end
