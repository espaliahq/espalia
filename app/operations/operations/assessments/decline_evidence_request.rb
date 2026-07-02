# frozen_string_literal: true

# Declines a pending evidence request, optionally with a reason. Requestee only.
#
# Write — :mcp_client.
class Operations::Assessments::DeclineEvidenceRequest < Operations::Base
  description "Decline a pending feedback / evidence request."
  category :write
  approval :mcp_client

  parameter :request_id, String, required: true
  parameter :reason, String

  def policy_check
    raise Pundit::NotAuthorizedError, "not linked to a person" if context.person.nil?

    authorize evidence_request, :decline?, policy_class: EvidenceRequestPolicy
  end

  # @return [Hash] { request_id, status }
  def perform
    PersonDevelopment::CommandHandler.new.decline_evidence_request(
      evidence_request.person_id, evidence_request.framework_id, evidence_request.id,
      declined_by_id: context.person.id, reason: params[:reason].presence
    )
    { request_id: evidence_request.id, status: "declined" }
  rescue PersonDevelopment::Aggregate::CommandError => e
    raise Operations::Base::ParameterError, e.message
  end

  private

  def evidence_request
    @evidence_request ||= EvidenceRequest.find(params[:request_id])
  end
end
