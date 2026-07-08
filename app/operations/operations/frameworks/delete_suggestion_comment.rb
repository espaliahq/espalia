# frozen_string_literal: true

# Soft-deletes a suggestion-thread comment — the row stays with
# `status: "deleted"` so reply chains and references stay coherent.
# Author or tenant admin ({FrameworkSuggestionCommentPolicy#destroy?}).
#
# Write — :mcp_client. A soft, audited, primarily author-scoped action.
class Operations::Frameworks::DeleteSuggestionComment < Operations::Base
  description "Delete a comment on a framework suggestion's thread (soft delete — preserves reply chains; author or tenant admin)."
  category :write
  approval :mcp_client

  parameter :framework_id, String, required: true
  parameter :comment_id,   String, required: true
  parameter :reason,       String

  # Author or tenant admin, never on an already-deleted comment.
  # @raise [Pundit::NotAuthorizedError]
  def policy_check
    authorize comment, :destroy?, policy_class: FrameworkSuggestionCommentPolicy
  end

  # @return [Hash] { framework_id:, comment_id:, status: }
  def perform
    Frameworks::CommandHandler.new.delete_suggestion_comment(
      framework.framework_id, comment.id,
      deleted_by_id: context.person.id.to_s, reason: params[:reason].presence
    )

    { framework_id: framework.framework_id, comment_id: comment.id, status: comment.reload.status }
  end

  private

  # Scoped to the authorized framework so a cross-framework comment_id
  # reads as not-found.
  def comment
    @comment ||= FrameworkState::SuggestionComment
      .for_framework(framework.framework_id)
      .find(params[:comment_id])
  end

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end
end
