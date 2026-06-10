# frozen_string_literal: true

# Withdraws an evidence item — a soft delete that hides it in EVERY cell it
# was linked to while preserving audit history (the row stays with
# `link_status: "withdrawn"`). Mirrors the web EvidenceController#destroy:
# same {EvidencePolicy#withdraw?} authorisation (author + tenant admin) and
# {PersonDevelopment::CommandHandler#withdraw_evidence} dispatch.
#
# Write — :mcp_client approval. Withdrawal is a soft, audited, primarily
# author-scoped action and is recoverable by recording the evidence again;
# the same friction as recording it is appropriate.
class Operations::Assessments::WithdrawEvidence < Operations::Base
  description "Withdraw an evidence item (soft delete — hides it everywhere, preserves history)."
  category :write
  approval :mcp_client

  parameter :assignment_id, String, required: true
  parameter :evidence_id,   String, required: true
  parameter :reason, String

  def policy_check
    raise Pundit::NotAuthorizedError, "not linked to a person" if context.person.nil?

    authorize evidence_item, :withdraw?, policy_class: EvidencePolicy
  end

  # @return [Hash] `{ evidence_id, status, withdrawn_at }` — confirmation
  #   the item is now withdrawn.
  def perform
    PersonDevelopment::CommandHandler.new.withdraw_evidence(
      assignment.person_id, assignment.framework_id, params[:evidence_id],
      withdrawn_by_id: context.person.id,
      reason: params[:reason].presence
    )

    item = EvidenceItem.find(params[:evidence_id])
    { evidence_id: item.id, status: item.link_status, withdrawn_at: item.withdrawn_at&.iso8601 }
  rescue PersonDevelopment::Aggregate::CommandError => e
    raise Operations::Base::ParameterError, e.message
  end

  private

  def assignment
    @assignment ||= PersonFrameworkAssignment.find(params[:assignment_id])
  end

  def evidence_item
    @evidence_item ||= EvidenceItem.find(params[:evidence_id])
  end
end
