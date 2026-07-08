# frozen_string_literal: true

# Revises the body of a suggestion-thread comment. Author-only — enforced
# by {FrameworkSuggestionCommentPolicy#update?} AND the aggregate (defense
# in depth, mirroring the assessment comment surface).
#
# Write — :mcp_client. Same friction as posting.
class Operations::Frameworks::EditSuggestionComment < Operations::Base
  description "Revise your own comment on a framework suggestion's discussion thread (author only)."
  category :write
  approval :mcp_client

  parameter :framework_id, String, required: true
  parameter :comment_id,   String, required: true
  parameter :body,         String, required: true

  # Author-only, never on a deleted comment.
  # @raise [Pundit::NotAuthorizedError]
  def policy_check
    authorize comment, :update?, policy_class: FrameworkSuggestionCommentPolicy
  end

  # @return [Hash] { framework_id:, comment_id:, body:, edited_at: }
  def perform
    validate_body!

    Frameworks::CommandHandler.new.edit_suggestion_comment(
      framework.framework_id, comment.id,
      body: params[:body].to_s, edited_by_id: context.person.id.to_s
    )

    edited = comment.reload
    {
      framework_id: framework.framework_id,
      comment_id: edited.id,
      body: edited.body,
      edited_at: edited.edited_at&.iso8601
    }
  end

  private

  def validate_body!
    return if params[:body].to_s.strip.present?

    raise Operations::Base::ParameterError, "body can't be blank"
  end

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
