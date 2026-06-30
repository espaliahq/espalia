# frozen_string_literal: true

# Edit / withdraw evidence you've authored, from the evidence hub. Peer
# evidence often lives on an assessment the author can't otherwise view, so
# the hub is the author's home for managing it. Dispatches the shared
# Operations (web + MCP parity); author-only via {EvidencePolicy}.
class EvidenceItemsController < ApplicationController
  include EvidenceDiffSubmit

  before_action :require_person

  # PATCH /evidence_items/:id — the unified modal's edit submit (content and/or
  # links). The diff emits only what changed (no edited_at bump for links-only).
  def update
    # The author can edit; a content edit is gated again by UpdateEvidence's
    # own update? check inside the diff.
    authorize evidence_item, :add_link?, policy_class: EvidencePolicy

    apply_evidence_diff
    redirect_to evidence_hub_path, notice: "Feedback updated."
  rescue Operations::Base::ParameterError, PersonDevelopment::Aggregate::CommandError => e
    redirect_to evidence_hub_path, alert: e.message, status: :see_other
  end

  # DELETE /evidence_items/:id — withdraw
  def destroy
    authorize evidence_item, :withdraw?, policy_class: EvidencePolicy

    Operations::Assessments::WithdrawEvidence.call(
      context: pundit_user,
      params: { assignment_id: assignment_id, evidence_id: evidence_item.id, reason: params.dig(:evidence, :reason) }
    )
    redirect_to evidence_hub_path, notice: "Feedback withdrawn.", status: :see_other
  rescue Operations::Base::ParameterError, PersonDevelopment::Aggregate::CommandError => e
    redirect_to evidence_hub_path, alert: e.message, status: :see_other
  end

  private

  def require_person
    head :forbidden unless current_person
  end

  def evidence_item
    @evidence_item ||= EvidenceItem.find(params.expect(:id))
  end

  # The assignment WithdrawEvidence expects, derived from the item's coordinates.
  def assignment_id
    PersonFrameworkAssignment.where(person_id: evidence_item.person_id, framework_id: evidence_item.framework_id).pick(:id)
  end
end
