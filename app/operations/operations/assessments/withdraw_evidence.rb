# frozen_string_literal: true

# Withdraws an evidence item — a soft delete that hides it in EVERY cell it
# was linked to while preserving audit history (the row stays with
# `link_status: "withdrawn"`). Mirrors the web EvidenceController#destroy:
# same {EvidencePolicy#withdraw?} authorisation (author + tenant admin) and
# {PersonDevelopment::CommandHandler#withdraw_evidence} dispatch.
#
# Feedback about a forgotten person takes the one exception their stream
# allows: only its author may withdraw it, and with no reason, since a reason
# would be new text about someone the erase removed.
#
# Write — :mcp_client approval. Withdrawal is a soft, audited, primarily
# author-scoped action and is recoverable by recording the evidence again;
# the same friction as recording it is appropriate.
class Operations::Assessments::WithdrawEvidence < Operations::Base
  description "Withdraw a feedback / evidence item (soft delete — hides it everywhere, preserves history). Feedback about a forgotten person can be withdrawn only by its author, and without a reason."
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
    if Person.find(assignment.person_id).forgotten?
      withdraw_about_former_member
    else
      PersonDevelopment::CommandHandler.new.withdraw_evidence(
        assignment.person_id, assignment.framework_id, params[:evidence_id],
        withdrawn_by_id: context.person.id,
        reason: params[:reason].presence
      )
    end

    item = EvidenceItem.find(params[:evidence_id])
    { evidence_id: item.id, status: item.link_status, withdrawn_at: item.withdrawn_at&.iso8601 }
  rescue PersonDevelopment::Aggregate::CommandError => e
    raise Operations::Base::ParameterError, e.message
  end

  private

  def withdraw_about_former_member
    raise Operations::Base::ParameterError, "only its author can withdraw feedback about a former member" unless evidence_item.author_id == context.person.id
    raise Operations::Base::ParameterError, "feedback about a former member is withdrawn without a reason" if params[:reason].present?

    PersonDevelopment::CommandHandler.new.withdraw_own_feedback(
      assignment.person_id, assignment.framework_id, params[:evidence_id],
      author_id: context.person.id
    )
  end

  def assignment
    @assignment ||= PersonFrameworkAssignment.find(params[:assignment_id])
  end

  def evidence_item
    @evidence_item ||= EvidenceItem.find(params[:evidence_id])
  end
end
