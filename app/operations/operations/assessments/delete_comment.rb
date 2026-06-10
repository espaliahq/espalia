# frozen_string_literal: true

# Soft-deletes a comment — the row stays with `status: "deleted"` so reply
# chains and any references stay coherent. Mirrors the web
# CommentsController#destroy: same {PersonDevelopmentCommentPolicy#destroy?}
# authorisation (author + tenant admin, not already deleted) and
# {PersonDevelopment::CommandHandler#delete_comment} dispatch.
#
# Write — :mcp_client approval. Deletion is a soft, audited, primarily
# author-scoped action; the same friction as posting it is appropriate.
class Operations::Assessments::DeleteComment < Operations::Base
  description "Delete a comment on an assessment (soft delete — preserves reply chains; author or tenant admin)."
  category :write
  approval :mcp_client

  parameter :assignment_id, String, required: true
  parameter :comment_id,    String, required: true
  parameter :reason, String

  def policy_check
    raise Pundit::NotAuthorizedError, "not linked to a person" if context.person.nil?

    authorize comment, :destroy?, policy_class: PersonDevelopmentCommentPolicy
  end

  # @return [Hash] `{ comment_id, status }` — confirmation the comment is
  #   now deleted.
  def perform
    PersonDevelopment::CommandHandler.new.delete_comment(
      assignment.person_id, assignment.framework_id, params[:comment_id],
      deleted_by_id: context.person.id,
      reason: params[:reason].presence
    )

    deleted = PersonDevelopmentComment.find(params[:comment_id])
    { comment_id: deleted.id, status: deleted.status }
  rescue PersonDevelopment::Aggregate::CommandError => e
    raise Operations::Base::ParameterError, e.message
  end

  private

  def assignment
    @assignment ||= PersonFrameworkAssignment.find(params[:assignment_id])
  end

  def comment
    @comment ||= PersonDevelopmentComment.find(params[:comment_id])
  end
end
