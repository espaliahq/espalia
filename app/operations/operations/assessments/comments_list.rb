# frozen_string_literal: true

# Lists the active comment threads on an assessment for one capability
# (optionally one level) — the read drill-in that closes the assessment →
# capability → comments traversal. Top-level comments each carry their
# active replies nested, so an LLM sees the conversation structure.
#
# Read-only; scoped by {PersonDevelopmentCommentPolicy#index?} (assessee +
# their manager chain + active rating delegate + tenant admin). Peers — who
# can record evidence but cannot see the assessment — are denied, matching
# the web comment surface (conversation context follows the assessment's
# audience).
#
# Soft-deleted comments are omitted. A deleted parent with active replies is
# an edge case we don't reconstruct here: only top-level ACTIVE comments and
# their active replies are returned (the full audit trail lives on the
# stream).
class Operations::Assessments::CommentsList < Operations::Base
  description "List active comment threads on an assessment for one capability (optionally one level). " \
              "Accepts either capability_id (version-specific) or stable_id (cross-version) in the " \
              "capability_stable_id argument. Top-level comments carry their replies nested."
  category :read
  approval :none

  parameter :assignment_id,        String, required: true
  parameter :capability_stable_id, String, required: true
  parameter :level_ordinal,        Integer

  def policy_check
    authorize assignment, :index?, policy_class: PersonDevelopmentCommentPolicy
  end

  # @return [Hash] `{ capability_stable_id:, level_ordinal:, comments: [...] }`
  #   where each top-level comment carries `{ id, capability_stable_id,
  #   level_ordinal, body, author{id,name}, posted_at, edited_at|nil,
  #   replies[] }` and each reply the same minus `replies`.
  def perform
    active = scoped_comments.includes(:author).to_a
    replies_by_parent = active.select(&:parent_id).group_by(&:parent_id)

    top_level = active.select { |c| c.parent_id.nil? }.sort_by(&:posted_at)

    {
      capability_stable_id: capability.stable_id,
      level_ordinal: params[:level_ordinal],
      comments: top_level.map do |comment|
        comment_payload(comment).merge(
          replies: (replies_by_parent[comment.id] || []).sort_by(&:posted_at).map { |r| comment_payload(r) }
        )
      end
    }
  end

  private

  def assignment
    @assignment ||= PersonFrameworkAssignment.find(params[:assignment_id])
  end

  # Resolve the capability within the assignment's framework, accepting
  # either the version-specific capability_id or the cross-version
  # stable_id. Scoped to the framework so a capability from a sibling
  # framework in the same tenant can't be requested (see mcp-server.md
  # Hard-Won Lesson 5).
  def capability
    @capability ||= begin
      scope = FrameworkState::Capability
        .joins(:category)
        .where(framework_capability_categories: { framework_id: assignment.framework_id })
      identifier = params[:capability_stable_id]
      scope.find_by(stable_id: identifier) || scope.find_by!(capability_id: identifier)
    end
  end

  # Active comments for the assessee on this framework, anchored to the
  # capability cell(s). Includes both top-level and replies so the payload
  # can be assembled into threads in memory.
  def scoped_comments
    scope = PersonDevelopmentComment.active
      .for_person(assignment.person_id)
      .for_framework(assignment.framework_id)
      .where(commentable_type: PersonDevelopmentComment::ASSESSMENT_CELL,
             capability_stable_id: capability.stable_id)
      .chronological
    scope = scope.where(level_ordinal: params[:level_ordinal]) if params[:level_ordinal]
    scope
  end

  def comment_payload(comment)
    {
      id: comment.id,
      capability_stable_id: comment.capability_stable_id,
      level_ordinal: comment.level_ordinal,
      body: comment.body,
      author: { id: comment.author_id, name: comment.author&.name },
      posted_at: comment.posted_at&.iso8601,
      edited_at: comment.edited_at&.iso8601
    }
  end
end
