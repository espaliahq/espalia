# frozen_string_literal: true

# Edits the body of an existing comment. Mirrors the web
# CommentsController#update: same {PersonDevelopmentCommentPolicy#update?}
# authorisation (original author only, not deleted) and
# {PersonDevelopment::CommandHandler#edit_comment} dispatch.
#
# Write — :mcp_client approval. Editing your own comment is a routine,
# author-scoped change; the MCP client's own write prompt is enough friction.
class Operations::Assessments::EditComment < Operations::Base
  description "Edit the body of one of your own comments on an assessment." + " " + Prose::MCP_NOTE
  category :write
  approval :mcp_client

  parameter :assignment_id, String, required: true
  parameter :comment_id,    String, required: true
  parameter :body, String, required: true

  def policy_check
    raise Pundit::NotAuthorizedError, "not linked to a person" if context.person.nil?

    authorize comment, :update?, policy_class: PersonDevelopmentCommentPolicy
  end

  # @return [Hash] `{ comment_id, body, edited_at }`.
  def perform
    validate_body!

    PersonDevelopment::CommandHandler.new.edit_comment(
      assignment.person_id, assignment.framework_id, params[:comment_id],
      body: params[:body].to_s,
      edited_by_id: context.person.id
    )

    updated = PersonDevelopmentComment.find(params[:comment_id])
    { comment_id: updated.id, body: updated.body, edited_at: updated.edited_at&.iso8601 }
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

  def validate_body!
    return if params[:body].to_s.strip.present?

    raise Operations::Base::ParameterError, "body cannot be blank"
  end
end
