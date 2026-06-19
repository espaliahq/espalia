# frozen_string_literal: true

# Web actions for evidence requests, all dispatching the shared
# Operations::Assessments::* classes (web + MCP parity). Create is driven from
# the assessment matrix (per-cell "Request evidence"); respond / decline /
# cancel are driven from the evidence hub.
class EvidenceRequestsController < ApplicationController
  before_action :require_person

  # POST /evidence_requests
  def create
    assignment = PersonFrameworkAssignment.find(create_params[:assignment_id])
    authorize assignment, :request?, policy_class: EvidenceRequestPolicy

    attrs = create_params.to_h.symbolize_keys
    attrs[:level_ordinal] = Integer(attrs[:level_ordinal], exception: false)
    Operations::Assessments::RequestEvidence.call(context: pundit_user, params: attrs)
    redirect_back fallback_location: evidence_hub_path, notice: "Evidence request sent."
  rescue ActiveRecord::RecordNotFound
    redirect_back fallback_location: evidence_hub_path, alert: "Assignment not found.", status: :see_other
  rescue Operations::Base::ParameterError, PersonDevelopment::Aggregate::CommandError => e
    redirect_back fallback_location: evidence_hub_path, alert: e.message, status: :see_other
  end

  # POST /evidence_requests/:id/respond
  def respond
    authorize evidence_request, :respond?, policy_class: EvidenceRequestPolicy

    Operations::Assessments::RespondToEvidenceRequest.call(
      context: pundit_user,
      params: respond_attrs
    )
    redirect_to evidence_hub_path, notice: "Evidence provided. Thank you!"
  rescue Operations::Base::ParameterError, PersonDevelopment::Aggregate::CommandError => e
    redirect_to evidence_hub_path, alert: e.message, status: :see_other
  end

  # POST /evidence_requests/:id/decline
  def decline
    authorize evidence_request, :decline?, policy_class: EvidenceRequestPolicy

    Operations::Assessments::DeclineEvidenceRequest.call(
      context: pundit_user,
      params: { request_id: evidence_request.id, reason: params.dig(:evidence_request, :reason) }
    )
    redirect_to evidence_hub_path, notice: "Request declined."
  rescue Operations::Base::ParameterError, PersonDevelopment::Aggregate::CommandError => e
    redirect_to evidence_hub_path, alert: e.message, status: :see_other
  end

  # DELETE /evidence_requests/:id — cancel
  def destroy
    authorize evidence_request, :cancel?, policy_class: EvidenceRequestPolicy

    Operations::Assessments::CancelEvidenceRequest.call(
      context: pundit_user, params: { request_id: evidence_request.id }
    )
    redirect_to evidence_hub_path, notice: "Request cancelled.", status: :see_other
  rescue Operations::Base::ParameterError, PersonDevelopment::Aggregate::CommandError => e
    redirect_to evidence_hub_path, alert: e.message, status: :see_other
  end

  private

  def require_person
    head :forbidden unless current_person
  end

  def evidence_request
    @evidence_request ||= EvidenceRequest.find(params.expect(:id))
  end

  def create_params
    params.expect(evidence_request: [ :assignment_id, :requestee_person_id, :capability_stable_id, :level_ordinal, :message, :due_at ])
  end

  def respond_params
    params.expect(evidence_request: [ :evidence_type, :content, :custom_type_label, :title,
                                      { external_reference: [ :system, :url ] } ])
  end

  # Build the operation params, dropping a blank external reference (an empty
  # system/url pair from the form) so it isn't treated as a real link.
  def respond_attrs
    attrs = respond_params.to_h.symbolize_keys.merge(request_id: evidence_request.id)
    ref = attrs[:external_reference]
    attrs.delete(:external_reference) unless ref.present? && ref["url"].present?
    attrs
  end
end
