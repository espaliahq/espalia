# frozen_string_literal: true

# Shared by the Framework Explorer's inline-edit controllers (capability,
# category, expectation, illustration). Routes an inline text edit through
# `suggest_edit` OR `amend_suggestion`, so consecutive edits to the same field
# by the same author don't stack as separate suggestions.
#
# When the author already has a PENDING edit on this (entity, field), the new
# value AMENDS it (→ SuggestionAmended, which renders distinctly in the activity
# feed and keeps a single row on the all-suggestions page). Otherwise a fresh
# suggestion is created — which, in editing mode for an authority-holder,
# auto-approves and applies live (so no pending suggestion lingers, and the next
# edit creates a fresh one rather than amending an already-applied change).
module InlineSuggestedEdits
  extend ActiveSupport::Concern

  private

  # @param framework_id [String]
  # @param entity_type [String] e.g. "capability", "capability_category"
  # @param entity_id [String]
  # @param field [String] e.g. "name", "description"
  # @param value [String] the proposed value
  # @param author_id [String] the suggesting person's id
  # @param mode [Symbol] :editing or :suggesting (only affects a fresh suggestion)
  # @return [void]
  def submit_inline_suggested_edit(framework_id:, entity_type:, entity_id:, field:, value:, author_id:, mode:)
    handler = Frameworks::CommandHandler.new
    existing = author_pending_edit(framework_id:, entity_type:, entity_id:, field:, author_id:)

    if existing
      handler.amend_suggestion(framework_id, existing.suggestion_id, value, author_id)
    else
      handler.suggest_edit(framework_id, SecureRandom.uuid_v7, entity_type, entity_id,
                           field, value, author_id, mode: mode)
    end
  end

  # The author's own pending edit on this exact (entity, field), if any.
  #
  # @return [FrameworkState::SuggestedEdit, nil]
  def author_pending_edit(framework_id:, entity_type:, entity_id:, field:, author_id:)
    FrameworkState::SuggestedEdit
      .pending.edits
      .for_entity(entity_type, entity_id)
      .where(framework_id: framework_id, field: field, author_id: author_id)
      .order(created_at: :desc)
      .first
  end
end
