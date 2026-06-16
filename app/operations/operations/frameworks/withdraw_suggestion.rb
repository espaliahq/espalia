# frozen_string_literal: true

# Withdraws the author's own pending suggested edit — the author retracting a
# proposal before a reviewer acts on it.
#
# Author-only while pending (FrameworkSuggestionPolicy#withdraw?).
class Operations::Frameworks::WithdrawSuggestion < Operations::Base
  description "Withdraw your own pending framework suggested edit (author only)."
  category :write
  approval :mcp_client

  parameter :framework_id,  String, required: true
  parameter :suggestion_id, String, required: true

  def policy_check
    authorize suggestion, :withdraw?
  end

  # @return [Hash] { framework_id:, suggestion_id:, status: }
  def perform
    Frameworks::CommandHandler.new.withdraw_suggestion(
      framework.framework_id,
      suggestion.suggestion_id,
      context.person&.id&.to_s
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
