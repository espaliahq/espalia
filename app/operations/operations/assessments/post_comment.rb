# frozen_string_literal: true

# Posts a comment on one capability × level of an assessment, optionally as
# a reply to an existing comment. Mirrors the web CommentsController#create:
# same {PersonDevelopmentCommentPolicy#create?} authorisation (anyone who
# can view the assessment) and {PersonDevelopment::CommandHandler#post_comment}
# dispatch.
#
# V1 supports only assessment-cell comments. The capability is anchored by
# its cross-version `capability_stable_id` (matching the evidence write
# tools); a version-specific capability_id is rejected by the
# framework-scope check.
#
# Write — :mcp_client approval. A comment is additive conversation context
# (it grants no permissions and changes no one's data); the MCP client's own
# write prompt is the right friction.
class Operations::Assessments::PostComment < Operations::Base
  description "Post a comment on a capability × level of an assessment (optionally as a reply)."
  category :write
  approval :mcp_client

  parameter :assignment_id,        String, required: true
  parameter :capability_stable_id, String, required: true
  parameter :level_ordinal,        Integer, required: true
  parameter :body, String, required: true
  parameter :parent_id, String # reply to an existing comment

  def policy_check
    raise Pundit::NotAuthorizedError, "not linked to a person" if context.person.nil?

    authorize assignment, :create?, policy_class: PersonDevelopmentCommentPolicy
  end

  # @return [Hash] `{ comment_id, capability_stable_id, level_ordinal,
  #   parent_id, body, posted_at }`.
  def perform
    validate_body!
    validate_level_ordinal!
    validate_capability_in_framework!

    comment_id = SecureRandom.uuid_v7
    PersonDevelopment::CommandHandler.new.post_comment(
      assignment.person_id, assignment.framework_id, comment_id,
      commentable_type: PersonDevelopmentComment::ASSESSMENT_CELL,
      capability_stable_id: params[:capability_stable_id],
      level_ordinal: params[:level_ordinal],
      body: params[:body].to_s,
      author_id: context.person.id,
      parent_id: params[:parent_id].presence
    )

    comment = PersonDevelopmentComment.find(comment_id)
    {
      comment_id: comment.id,
      capability_stable_id: comment.capability_stable_id,
      level_ordinal: comment.level_ordinal,
      parent_id: comment.parent_id,
      body: comment.body,
      posted_at: comment.posted_at&.iso8601
    }
  rescue PersonDevelopment::Aggregate::CommandError => e
    raise Operations::Base::ParameterError, e.message
  end

  private

  def assignment
    @assignment ||= PersonFrameworkAssignment.find(params[:assignment_id])
  end

  def validate_body!
    return if params[:body].to_s.strip.present?

    raise Operations::Base::ParameterError, "body cannot be blank"
  end

  def validate_level_ordinal!
    return if FrameworkState::Level.exists?(role_id: assignment.role_id, ordinal: params[:level_ordinal])

    raise Operations::Base::ParameterError,
      "level_ordinal #{params[:level_ordinal]} does not exist for the assignment's role"
  end

  # Guard against anchoring a comment to a capability outside this
  # assessment's framework (the lookup is scoped to the assignment's
  # framework, so a foreign / version-specific id resolves to absent).
  def validate_capability_in_framework!
    in_framework = FrameworkState::Capability
      .joins(:category)
      .where(stable_id: params[:capability_stable_id])
      .merge(FrameworkState::CapabilityCategory.where(framework_id: assignment.framework_id))
      .exists?
    return if in_framework

    raise Operations::Base::ParameterError,
      "capability_stable_id does not belong to the assignment's framework"
  end
end
