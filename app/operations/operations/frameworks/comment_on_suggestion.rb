# frozen_string_literal: true

# Posts a comment on a framework suggestion's discussion thread, optionally
# as a reply to an existing comment on the same suggestion.
#
# Threads stay open after resolution — commenting on an approved / rejected /
# withdrawn suggestion is allowed (the PR-conversation convention). A reply
# may target ANY non-deleted comment on the suggestion, including another
# reply; display is flat with one indent level.
#
# Write — :mcp_client. A comment is additive conversation context (it grants
# no permissions and changes no framework content); the same friction as
# posting a suggestion is the right bar.
class Operations::Frameworks::CommentOnSuggestion < Operations::Base
  description "Comment on a framework suggestion's discussion thread (optionally as a reply). Threads stay open after the suggestion is resolved." + " " + Prose::MCP_NOTE
  category :write
  approval :mcp_client

  parameter :framework_id,  String, required: true
  parameter :suggestion_id, String, required: true
  parameter :body,          String, required: true
  parameter :parent_id,     String # reply to an existing comment

  # Same bar as submitting a suggestion (suggest-rights collaborators +
  # tenant admins with a linked person for attribution).
  # @raise [Pundit::NotAuthorizedError]
  def policy_check
    authorize framework, :comment_on_suggestion?
  end

  # @return [Hash] { framework_id:, suggestion_id:, comment_id:, parent_id:, body:, posted_at: }
  def perform
    validate_body!
    require_author!
    ensure_suggestion_exists!
    validate_parent!

    comment_id = SecureRandom.uuid_v7
    Frameworks::CommandHandler.new.comment_on_suggestion(
      framework.framework_id, params[:suggestion_id], comment_id,
      body: params[:body].to_s,
      author_id: context.person.id.to_s,
      parent_id: params[:parent_id].presence
    )

    comment = FrameworkState::SuggestionComment.find(comment_id)
    {
      framework_id: framework.framework_id,
      suggestion_id: comment.suggestion_id,
      comment_id: comment.id,
      parent_id: comment.parent_id,
      body: comment.body,
      posted_at: comment.posted_at&.iso8601
    }
  end

  private

  def validate_body!
    return if params[:body].to_s.strip.present?

    raise Operations::Base::ParameterError, "body can't be blank"
  end

  # Commenting needs an author for attribution — a tenant admin with no
  # linked Person passes the policy but can't attribute the comment.
  def require_author!
    return if context.person.present?

    raise Operations::Base::ParameterError,
          "Commenting requires a linked person; this account has none."
  end

  # The suggestion must belong to the authorized framework (any status —
  # threads stay open after resolution).
  def ensure_suggestion_exists!
    return if suggestion.present?

    raise ActiveRecord::RecordNotFound,
          "suggestion #{params[:suggestion_id]} not found in this framework"
  end

  # Pre-check the reply target so a client mistake classifies as invalid
  # params rather than the aggregate's RuntimeError (→ internal error).
  def validate_parent!
    return if params[:parent_id].blank?

    parent = FrameworkState::SuggestionComment
      .for_framework(framework.framework_id)
      .find_by(id: params[:parent_id])

    raise Operations::Base::ParameterError, "parent comment not found" if parent.nil?
    raise Operations::Base::ParameterError, "cannot reply to a deleted comment" if parent.deleted?
    return if parent.suggestion_id == params[:suggestion_id]

    raise Operations::Base::ParameterError, "parent comment belongs to a different suggestion"
  end

  def suggestion
    @suggestion ||= FrameworkState::SuggestedEdit
      .where(framework_id: framework.framework_id)
      .find_by(suggestion_id: params[:suggestion_id])
  end

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end
end
