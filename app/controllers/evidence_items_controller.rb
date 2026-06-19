# frozen_string_literal: true

# Edit / withdraw evidence you've authored, from the evidence hub. Peer
# evidence often lives on an assessment the author can't otherwise view, so
# the hub is the author's home for managing it. Dispatches the shared
# Operations (web + MCP parity); author-only via {EvidencePolicy}.
class EvidenceItemsController < ApplicationController
  before_action :require_person

  # PATCH /evidence_items/:id
  def update
    authorize evidence_item, :update?, policy_class: EvidencePolicy

    Operations::Assessments::UpdateEvidence.call(context: pundit_user, params: update_attrs)
    redirect_to evidence_hub_path, notice: "Evidence updated."
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
    redirect_to evidence_hub_path, notice: "Evidence withdrawn.", status: :see_other
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

  # The assignment the operations expect, derived from the item's coordinates.
  def assignment_id
    PersonFrameworkAssignment.where(person_id: evidence_item.person_id, framework_id: evidence_item.framework_id).pick(:id)
  end

  def update_attrs
    permitted = params.expect(evidence: [ :evidence_type, :content, :custom_type_label, :title,
                                          { external_reference: [ :system, :url ] } ])
    attrs = permitted.to_h.symbolize_keys.merge(assignment_id: assignment_id, evidence_id: evidence_item.id)
    ref = attrs[:external_reference]
    attrs.delete(:external_reference) unless ref.present? && ref["url"].present?
    attrs
  end
end
