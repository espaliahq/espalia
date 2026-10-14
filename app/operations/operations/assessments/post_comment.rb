# frozen_string_literal: true

# Posts a comment on one capability × level of an assessment, optionally as
# a reply to an existing comment. Mirrors the web CommentsController#create:
# same {PersonDevelopmentCommentPolicy#create?} authorisation (anyone who
# can view the assessment) and {PersonDevelopment::CommandHandler#post_comment}
# dispatch.
#
# Anchors to an assessment cell by default; passing `evidence_id`
# anchors the comment to that evidence item's LINKAGE at the cell
# instead — the discussion thread about the feedback's relevance and
# valence there (the cell coordinates then name the linkage, and their
# validity is the aggregate's ever-linked check rather than the role's
# level list). The capability is anchored by its cross-version
# `capability_stable_id` (matching the evidence write tools); a
# version-specific capability_id is rejected by the framework-scope check.
#
# Write — :mcp_client approval. A comment is additive conversation context
# (it grants no permissions and changes no one's data); the MCP client's own
# write prompt is the right friction.
class Operations::Assessments::PostComment < Operations::Base
  description "Post a comment on a capability × level of an assessment (optionally as a reply). " \
              "Pass evidence_id to comment on that evidence item's linkage at the cell instead — " \
              "the discussion of the feedback's relevance and valence there."
  category :write
  approval :mcp_client
  prose_fields :body

  parameter :assignment_id,        String, required: true
  parameter :capability_stable_id, String, required: true
  parameter :level_ordinal,        Integer, required: true
  parameter :body, String, required: true
  parameter :parent_id, String # reply to an existing comment
  parameter :evidence_id, String # comment on this evidence item's linkage at the cell

  def policy_check
    raise Pundit::NotAuthorizedError, "not linked to a person" if context.person.nil?

    authorize assignment, :create?, policy_class: PersonDevelopmentCommentPolicy
  end

  # @return [Hash] `{ comment_id, capability_stable_id, level_ordinal,
  #   parent_id, body, posted_at }`.
  def perform
    validate_body!
    evidence_id = params[:evidence_id].presence
    # An evidence-link comment's coordinates name the linkage, and the
    # aggregate's ever-linked check owns their validity — a manager may
    # have linked at any ordinal, not just the assessee's role's levels.
    validate_level_ordinal! unless evidence_id
    validate_capability_in_framework!

    comment_id = SecureRandom.uuid_v7
    PersonDevelopment::CommandHandler.new.post_comment(
      assignment.person_id, assignment.framework_id, comment_id,
      commentable_type: evidence_id ? PersonDevelopmentComment::EVIDENCE_LINK
                                    : PersonDevelopmentComment::ASSESSMENT_CELL,
      capability_stable_id: params[:capability_stable_id],
      level_ordinal: params[:level_ordinal],
      evidence_id: evidence_id,
      body: params[:body].to_s,
      author_id: context.person.id,
      parent_id: params[:parent_id].presence
    )

    comment = PersonDevelopmentComment.find(comment_id)
    {
      comment_id: comment.id,
      capability_stable_id: comment.capability_stable_id,
      level_ordinal: comment.level_ordinal,
      evidence_id: comment.evidence_id,
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
