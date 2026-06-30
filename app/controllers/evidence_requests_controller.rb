# frozen_string_literal: true

# Web actions for evidence requests, all dispatching the shared
# Operations::Assessments::* classes (web + MCP parity). Create is driven from
# the assessment matrix (per-cell "Request evidence"); respond / decline /
# cancel are driven from the evidence hub.
class EvidenceRequestsController < ApplicationController
  include EvidenceDiffSubmit

  before_action :require_person

  # GET /assessments/:assignment_id/evidence_request_modal — the request form,
  # rendered into the lazy #evidence-request-modal frame for a cell.
  def modal
    authorize modal_assignment, :request?, policy_class: EvidenceRequestPolicy
    cap = params[:capability_stable_id]
    lvl = cell_level_ordinal or return head(:bad_request)
    render Views::Evidence::RequestForm.new(
      assignment_id: modal_assignment.id, capability_stable_id: cap, level_ordinal: lvl,
      context_block: cell_context(cap, lvl),
      suggestions: candidates_query(cap, lvl).suggestions,
      submit_url: evidence_requests_path,
      candidates_url: evidence_request_candidates_path(
        assignment_id: modal_assignment.id, capability_stable_id: cap, level_ordinal: lvl
      )
    ), layout: false
  end

  # GET /assessments/:assignment_id/evidence_request_candidates?q= — the
  # debounced typeahead results frame.
  def candidates
    authorize modal_assignment, :request?, policy_class: EvidenceRequestPolicy
    cap = params[:capability_stable_id]
    lvl = cell_level_ordinal or return head(:bad_request)
    render Views::Evidence::RequestCandidatesFrame.new(
      candidates: candidates_query(cap, lvl).search(params[:q]), query: params[:q].presence
    ), layout: false
  end

  # POST /evidence_requests — multi-send: one request per recipient, one shared
  # reason. Loops the single-recipient RequestEvidence op (web convenience; MCP
  # parity unchanged) and flashes a per-batch summary.
  def create
    assignment = PersonFrameworkAssignment.find(create_params[:assignment_id])
    authorize assignment, :request?, policy_class: EvidenceRequestPolicy

    sent, skipped = send_requests(assignment)
    redirect_back fallback_location: evidence_hub_path, **request_flash(sent, skipped)
  rescue ActiveRecord::RecordNotFound
    redirect_back fallback_location: evidence_hub_path, alert: "Assignment not found.", status: :see_other
  end

  # POST /evidence_requests/:id/respond — the unified modal's respond submit.
  def respond
    authorize evidence_request, :respond?, policy_class: EvidenceRequestPolicy

    apply_evidence_diff
    redirect_to evidence_hub_path, notice: "Feedback provided. Thank you!"
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

  def modal_assignment
    @modal_assignment ||= PersonFrameworkAssignment.find(params.expect(:assignment_id))
  end

  # The cell level as an integer, or nil when the param is missing/malformed
  # (the modal/candidates frames can't be rendered without a real cell).
  def cell_level_ordinal
    Integer(params[:level_ordinal], exception: false)
  end

  def candidates_query(capability_stable_id, level_ordinal)
    Assessments::RequestCandidates.new(
      assignment: modal_assignment, requester_person_id: current_person.id,
      capability_stable_id:, level_ordinal:
    )
  end

  def cell_context(capability_stable_id, level_ordinal)
    Evidence::CellContextResolver.context(
      framework_id: modal_assignment.framework_id, person_id: modal_assignment.person_id,
      capability_stable_id:, level_ordinal:
    )
  end

  # Dispatch one RequestEvidence per recipient; collect the names we couldn't
  # send to (invalid id, pending dupe, etc.) for the summary flash.
  #
  # @return [Array(Integer, Array<String>)] sent count, skipped recipient labels
  def send_requests(assignment)
    cap = create_params[:capability_stable_id]
    lvl = Integer(create_params[:level_ordinal], exception: false)
    sent = 0
    skipped = []
    recipient_ids.each do |person_id|
      Operations::Assessments::RequestEvidence.call(context: pundit_user, params: {
        assignment_id: assignment.id, requestee_person_id: person_id,
        capability_stable_id: cap, level_ordinal: lvl,
        message: create_params[:message].presence, due_at: create_params[:due_at].presence
      })
      sent += 1
    rescue Operations::Base::ParameterError, PersonDevelopment::Aggregate::CommandError
      skipped << (Person.find_by(id: person_id)&.name || "someone")
    end
    [ sent, skipped ]
  end

  # De-duplicated recipient ids — `requestee_ids[]` (the multi-select form) plus
  # a legacy single `requestee_person_id` (MCP-shaped / older callers).
  def recipient_ids
    (Array(create_params[:requestee_ids]) + Array(create_params[:requestee_person_id])).map(&:presence).compact.uniq
  end

  def request_flash(sent, skipped)
    return { alert: "No requests sent — #{skipped.to_sentence} already asked or unavailable.", status: :see_other } if sent.zero?

    notice = "Feedback #{'request'.pluralize(sent)} sent to #{sent} #{'person'.pluralize(sent)}."
    notice += " Skipped #{skipped.size} (already asked or unavailable)." if skipped.any?
    { notice: notice }
  end

  def create_params
    params.expect(evidence_request: [
      :assignment_id, :requestee_person_id, :capability_stable_id, :level_ordinal, :message, :due_at,
      { requestee_ids: [] }
    ])
  end
end
