# frozen_string_literal: true

# Approves a pending framework suggested edit, applying the proposed change.
#
# Shape-preserving suggestions (text edits, illustrations) apply live. A
# shape-changing approval (create/delete of capability/expectation/level) only
# *stages* the change into an auto-opened draft — nothing reaches the published
# view until PublishVersion (which is :in_app), so approval itself stays
# :mcp_client. Approving also auto-rejects any competing pending edits on the
# same entity field (handled in the aggregate).
#
# Authority is tier-based (see FrameworkSuggestionPolicy#approve?): tenant admin,
# or a collaborator whose roles clear the suggestion's review tier.
class Operations::Frameworks::ApproveSuggestion < Operations::Base
  description "Approve a pending framework suggested edit (tier authority required)."
  category :write
  approval :mcp_client
  prose_fields :comment

  parameter :framework_id,  String, required: true
  parameter :suggestion_id, String, required: true
  parameter :comment,       String

  def policy_check
    authorize suggestion, :approve?
  end

  # @return [Hash] { framework_id:, suggestion_id:, status: }
  def perform
    Frameworks::CommandHandler.new.approve_suggestion(
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
