# frozen_string_literal: true

# Cancels a still-pending evidence request. Requester or tenant admin only.
#
# Write — :mcp_client.
class Operations::Assessments::CancelEvidenceRequest < Operations::Base
  description "Cancel a pending evidence request you created."
  category :write
  approval :mcp_client

  parameter :request_id, String, required: true

  def policy_check
    raise Pundit::NotAuthorizedError, "not linked to a person" if context.person.nil?

    authorize evidence_request, :cancel?, policy_class: EvidenceRequestPolicy
  end

  # @return [Hash] { request_id, status }
  def perform
    PersonDevelopment::CommandHandler.new.cancel_evidence_request(
      evidence_request.person_id, evidence_request.framework_id, evidence_request.id,
      cancelled_by_id: context.person.id
    )
    { request_id: evidence_request.id, status: "cancelled" }
  rescue PersonDevelopment::Aggregate::CommandError => e
    raise Operations::Base::ParameterError, e.message
  end

  private

  def evidence_request
    @evidence_request ||= EvidenceRequest.find(params[:request_id])
  end
end
