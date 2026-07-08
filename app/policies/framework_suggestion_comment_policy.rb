# frozen_string_literal: true

# Record-level authorization for suggestion discussion-thread comments —
# who may revise or remove an existing comment. Posting is authorized on
# the framework instead ({FrameworkPolicy#comment_on_suggestion?}).
#
# Mirrors {PersonDevelopmentCommentPolicy}: author-only edits; author or
# tenant admin deletes; nothing on an already-deleted comment.
class FrameworkSuggestionCommentPolicy < ApplicationPolicy
  # @return [Boolean]
  def update?
    return false unless person.present?
    return false unless record.is_a?(FrameworkState::SuggestionComment)
    return false if record.deleted?

    record.author_id == person.id
  end

  # @return [Boolean]
  def destroy?
    # Even a tenant admin needs a linked Person — the deletion event's
    # attribution is a person id (mirrors PersonDevelopmentCommentPolicy).
    return false unless person.present?
    return false unless record.is_a?(FrameworkState::SuggestionComment)
    # Reject redundant deletes on already-deleted comments — keeps flash
    # messaging consistent with update?, which mirrors the same guard.
    return false if record.deleted?
    return true if tenant_admin?

    record.author_id == person.id
  end
end
