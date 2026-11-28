# frozen_string_literal: true

# Withdraws an evidence item — a soft delete that hides it in EVERY cell it
# was linked to while preserving audit history (the row stays with
# `link_status: "withdrawn"`). Mirrors the web EvidenceController#destroy:
# same {EvidencePolicy#withdraw?} authorisation (author + tenant admin) and
# {PersonDevelopment::CommandHandler#withdraw_evidence} dispatch.
#
# Feedback about a forgotten person takes the one exception their stream
# allows: only its author may withdraw it, and with no reason, since a reason
# would be new text about someone the erase removed. It needs no
# assignment, since most forgotten people were offboarded first, so the
# stream comes from the item itself and `assignment_id` is optional there.
#
# Write — :mcp_client approval. Withdrawal is a soft, audited, primarily
# author-scoped action and is recoverable by recording the evidence again;
# the same friction as recording it is appropriate.
class Operations::Assessments::WithdrawEvidence < Operations::Base
  description "Withdraw a feedback / evidence item (soft delete — hides it everywhere, preserves history). assignment_id is required, except for feedback about a forgotten person, which takes the item's own assignment or none. That feedback can be withdrawn only by its author, and without a reason."
  category :write
  approval :mcp_client

  parameter :assignment_id, String
  parameter :evidence_id,   String, required: true
  parameter :reason, String

  def policy_check
    raise Pundit::NotAuthorizedError, "not linked to a person" if context.person.nil?

    authorize evidence_item, :withdraw?, policy_class: EvidencePolicy
  end

  # @return [Hash] `{ evidence_id, status, withdrawn_at }` — confirmation
  #   the item is now withdrawn.
  def perform
    ensure_assignment_matches_item!
    if Person.find(evidence_item.person_id).forgotten?
      withdraw_about_former_member
    else
      raise Operations::Base::ParameterError, "missing required parameter: assignment_id" if params[:assignment_id].blank?
      raise ActiveRecord::RecordNotFound, "Couldn't find PersonFrameworkAssignment" if assignment.nil?

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
      evidence_item.person_id, evidence_item.framework_id, params[:evidence_id],
      author_id: context.person.id
    )
  end

  def ensure_assignment_matches_item!
    return if assignment.nil?
    return if [ assignment.person_id, assignment.framework_id ] == [ evidence_item.person_id, evidence_item.framework_id ]

    raise Operations::Base::ParameterError, "evidence_id is not on that assignment"
  end

  def assignment
    return if params[:assignment_id].blank?

    @assignment ||= PersonFrameworkAssignment.find_by(id: params[:assignment_id])
  end

  def evidence_item
    @evidence_item ||= EvidenceItem.find(params[:evidence_id])
  end
end
