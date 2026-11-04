# frozen_string_literal: true

# Give, edit and withdraw evidence from the evidence hub. Peer evidence often
# lives on an assessment the author can't otherwise view, so the hub is the
# author's home for managing it — and, since feedback can be volunteered, for
# giving it. Dispatches the shared Operations (web + MCP parity), gated by
# {EvidencePolicy}.
class EvidenceItemsController < ApplicationController
  include EvidenceDiffSubmit
  include EvidenceHubReturn

  before_action :require_person

  # POST /evidence_items — the unified modal's :new submit from the hub:
  # feedback volunteered to a colleague, placed on the rows staged in the
  # form or recorded unplaced when there are none.
  def create
    assignment = PersonFrameworkAssignment.find(params.expect(evidence: [ :assignment_id ])[:assignment_id])
    authorize assignment, :create?, policy_class: EvidencePolicy

    touched = apply_evidence_diff
    FeedbackDraft.open_for(token: params[:draft_token], email: current_user.email)&.consume!
    notice = touched.cells.empty? ? "Feedback recorded — not yet placed on a capability." : "Feedback recorded."
    redirect_to hub_return_path, notice: notice, status: :see_other
  rescue Operations::Base::ParameterError, PersonDevelopment::Aggregate::CommandError => e
    redirect_to hub_return_path, alert: e.message, status: :see_other
  end

  # PATCH /evidence_items/:id — the unified modal's edit submit (content and/or
  # links). The diff emits only what changed (no edited_at bump for links-only).
  def update
    # The author can edit; a content edit is gated again by UpdateEvidence's
    # own update? check inside the diff.
    authorize evidence_item, :add_link?, policy_class: EvidencePolicy

    apply_evidence_diff
    redirect_to hub_return_path, notice: "Feedback updated."
  rescue Operations::Base::ParameterError, PersonDevelopment::Aggregate::CommandError => e
    redirect_to hub_return_path, alert: e.message, status: :see_other
  end

  # DELETE /evidence_items/:id — withdraw
  def destroy
    authorize evidence_item, :withdraw?, policy_class: EvidencePolicy

    Operations::Assessments::WithdrawEvidence.call(
      context: pundit_user,
      params: { assignment_id: assignment_id, evidence_id: evidence_item.id, reason: params.dig(:evidence, :reason) }
    )
    redirect_to hub_return_path, notice: "Feedback withdrawn.", status: :see_other
  rescue Operations::Base::ParameterError, PersonDevelopment::Aggregate::CommandError => e
    redirect_to hub_return_path, alert: e.message, status: :see_other
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
