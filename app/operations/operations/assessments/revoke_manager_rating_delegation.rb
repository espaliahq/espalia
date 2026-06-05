# frozen_string_literal: true

# Revokes a manager-rating delegation. Non-destructive — ratings the delegate
# already recorded remain, attributed to them; only future rating is stopped.
#
# Changes someone else's permissions, so :in_app approval (MCP defers to the
# web confirmation flow).
class Operations::Assessments::RevokeManagerRatingDelegation < Operations::Base
  description "Revoke a manager-rating delegation for one of your reports."
  category :write
  approval :in_app

  parameter :assignment_id,      String, required: true
  parameter :delegate_person_id, String, required: true

  def policy_check
    authorize assignment, :revoke_manager_rating_delegation?
  end

  # @return [Hash] `{ assignment_id, person_id, framework_id, delegate_person_id }`
  def perform
    PersonDevelopment::CommandHandler.new.revoke_manager_rating_delegation(
      assignment.person_id, assignment.framework_id, params[:delegate_person_id],
      revoked_by_id: context.person&.id
    )

    {
      assignment_id: params[:assignment_id],
      person_id: assignment.person_id,
      framework_id: assignment.framework_id,
      delegate_person_id: params[:delegate_person_id]
    }
  end

  private

  def assignment
    @assignment ||= PersonFrameworkAssignment.find(params[:assignment_id])
  end
end
