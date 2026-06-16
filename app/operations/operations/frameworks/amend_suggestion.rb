# frozen_string_literal: true

# Amends the author's own pending suggested edit — revising the proposed value
# (and optionally the rationale) before a reviewer acts on it.
#
# Author-only while pending (FrameworkSuggestionPolicy#amend?). Today amend
# applies to edit-kind suggestions only (mirrors the controller surface).
class Operations::Frameworks::AmendSuggestion < Operations::Base
  description "Revise your own pending framework suggested edit (author only)."
  category :write
  approval :mcp_client

  parameter :framework_id,    String, required: true
  parameter :suggestion_id,   String, required: true
  parameter :suggested_value, String, required: true
  parameter :rationale,       String

  def policy_check
    authorize suggestion, :amend?
  end

  # @return [Hash] { framework_id:, suggestion_id:, status: }
  def perform
    Frameworks::CommandHandler.new.amend_suggestion(
      framework.framework_id,
      suggestion.suggestion_id,
      params[:suggested_value],
      context.person&.id&.to_s,
      rationale: params[:rationale].presence
    )

    { framework_id: framework.framework_id, suggestion_id: suggestion.suggestion_id, status: suggestion.reload.status }
  end

  private

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end

  def suggestion
    @suggestion ||= framework.suggested_edits.find_by!(suggestion_id: params[:suggestion_id])
  end
end
