# frozen_string_literal: true

# Rejects a pending framework suggested edit, with an optional reviewer comment.
#
# The comment is surfaced in the activity feed (Entry#secondary_text) so the
# author sees why their proposal was declined. Authority mirrors approval —
# tier-based (FrameworkSuggestionPolicy#reject? aliases #approve?).
class Operations::Frameworks::RejectSuggestion < Operations::Base
  description "Reject a pending framework suggested edit, optionally with a reason (tier authority required)."
  category :write
  approval :mcp_client

  parameter :framework_id,  String, required: true
  parameter :suggestion_id, String, required: true
  parameter :comment,       String

  def policy_check
    authorize suggestion, :reject?
  end

  # @return [Hash] { framework_id:, suggestion_id:, status: }
  def perform
    Frameworks::CommandHandler.new.reject_suggestion(
      framework.framework_id,
      suggestion.suggestion_id,
      context.person&.id&.to_s,
      comment: params[:comment].presence
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
