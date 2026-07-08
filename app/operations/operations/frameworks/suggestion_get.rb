# frozen_string_literal: true

# Fetches one framework suggestion in full — the proposal (kind, target,
# values, rationale), its resolution (status, reviewer, reviewer comment),
# and its discussion thread (top-level comments with replies nested one
# level, matching assessments_comments_list's shape).
#
# Closes the suggestion read gap: the write lifecycle (suggest / approve /
# reject / amend / withdraw / comment) was fully exposed while discovery
# ran only through frameworks_recent_activity. This is the drill-in from a
# feed entry's suggestion_id.
#
# Soft-deleted comments are omitted; only active top-level comments and
# their active replies are returned (the full audit trail lives on the
# stream — same simplification as assessments_comments_list).
class Operations::Frameworks::SuggestionGet < Operations::Base
  description "Fetch one framework suggestion in full: proposal, resolution status, and its discussion thread (top-level comments with replies nested)."
  category :read
  approval :none

  parameter :framework_id,  String, required: true
  parameter :suggestion_id, String, required: true

  # Same gate as the web suggestion surfaces (suggest-rights collaborators
  # + tenant admins).
  # @raise [Pundit::NotAuthorizedError]
  def policy_check
    authorize framework, :view_suggestions?
  end

  # @return [Hash] the suggestion payload with a nested `comments:` thread.
  def perform
    {
      framework_id: framework.framework_id,
      suggestion_id: suggestion.suggestion_id,
      kind: suggestion.kind,
      status: suggestion.status,
      target_entity_type: suggestion.target_entity_type,
      target_entity_id: suggestion.target_entity_id,
      field: suggestion.field,
      current_value: suggestion.current_value,
      suggested_value: suggestion.suggested_value,
      proposed_attributes: suggestion.proposed_attributes.presence,
      parent_id: suggestion.parent_id,
      rationale: suggestion.rationale,
      author: person_ref(suggestion.author_id),
      reviewed_by: person_ref(suggestion.reviewed_by),
      reviewed_at: suggestion.reviewed_at&.iso8601,
      reviewer_comment: suggestion.reviewer_comment,
      created_at: suggestion.created_at.iso8601,
      comments: thread
    }
  end

  private

  # Top-level active comments with their active replies nested one level.
  def thread
    active = FrameworkState::SuggestionComment.active
      .for_suggestion(suggestion.suggestion_id)
      .includes(:author)
      .chronological
      .to_a
    replies_by_parent = active.select(&:parent_id).group_by(&:parent_id)

    active.select { |c| c.parent_id.nil? }.map do |comment|
      comment_payload(comment).merge(
        replies: (replies_by_parent[comment.id] || []).map { |r| comment_payload(r) }
      )
    end
  end

  def comment_payload(comment)
    {
      id: comment.id,
      body: comment.body,
      author: { id: comment.author.id, name: comment.author.name },
      posted_at: comment.posted_at&.iso8601,
      edited_at: comment.edited_at&.iso8601
    }
  end

  def person_ref(person_id)
    return nil if person_id.blank?

    person = Person.find_by(id: person_id)
    person && { id: person.id, name: person.name }
  end

  def suggestion
    @suggestion ||= FrameworkState::SuggestedEdit
      .where(framework_id: framework.framework_id)
      .find_by(suggestion_id: params[:suggestion_id]) ||
      raise(ActiveRecord::RecordNotFound,
            "suggestion #{params[:suggestion_id]} not found in this framework")
  end

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end
end
