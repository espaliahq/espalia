# frozen_string_literal: true

# Grants manager-rating authority for one of your reports on a framework to
# another person — e.g. when the report is seconded into another team and their
# reporting manager hands rating to someone closer to the work.
#
# The delegate may record manager ratings but NOT start, complete, or record
# alignment. Granting authority changes someone else's permissions, so this is
# an :in_app approval — MCP defers it to the web confirmation flow.
class Operations::Assessments::DelegateManagerRating < Operations::Base
  description "Delegate manager-rating authority for one of your reports to another person."
  category :write
  approval :in_app

  parameter :assignment_id,      String, required: true
  parameter :delegate_person_id, String, required: true
  parameter :expires_at,         String
  parameter :reason,             String

  def policy_check
    authorize assignment, :delegate_manager_rating?
  end

  # @return [Hash] `{ assignment_id, person_id, framework_id, delegate_person_id, expires_at }`
  def perform
    PersonDevelopment::CommandHandler.new.delegate_manager_rating(
      assignment.person_id, assignment.framework_id, delegate.id,
      granted_by_id: context.person&.id,
      expires_at: params[:expires_at].presence,
      reason: params[:reason].presence
    )

    {
      assignment_id: params[:assignment_id],
      person_id: assignment.person_id,
      framework_id: assignment.framework_id,
      delegate_person_id: delegate.id,
      expires_at: params[:expires_at].presence
    }
  end

  private

  def assignment
    @assignment ||= PersonFrameworkAssignment.find(params[:assignment_id])
  end

  def delegate
    @delegate ||= Person.find(params[:delegate_person_id])
  end
end
