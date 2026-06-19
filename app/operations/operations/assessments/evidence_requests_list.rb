# frozen_string_literal: true

# Lists evidence requests addressed to the caller (incoming) and ones the
# caller made (outgoing). Read — :none. Scoped to the caller's own person, so
# no per-record authorization beyond "is a person" is needed.
class Operations::Assessments::EvidenceRequestsList < Operations::Base
  description "List evidence requests addressed to you (incoming) and ones you've made (outgoing)."
  category :read
  approval :none

  parameter :status, String, allowed: EvidenceRequest::STATUSES

  def policy_check
    raise Pundit::NotAuthorizedError, "not linked to a person" if context.person.nil?

    authorize EvidenceRequest, :index?, policy_class: EvidenceRequestPolicy
  end

  # @return [Hash] { incoming: [...], outgoing: [...] }
  def perform
    person_id = context.person.id
    {
      incoming: serialize(EvidenceRequest.incoming_for(person_id)),
      outgoing: serialize(EvidenceRequest.outgoing_for(person_id))
    }
  end

  private

  def serialize(scope)
    scope = scope.where(status: params[:status]) if params[:status].present?
    scope.recent_first.includes(:requester, :requestee).map do |req|
      {
        request_id: req.id,
        status: req.status,
        framework_id: req.framework_id,
        capability_stable_id: req.capability_stable_id,
        level_ordinal: req.level_ordinal,
        requester: { id: req.requested_by_id, name: req.requester&.name },
        requestee: { id: req.requestee_person_id, name: req.requestee&.name },
        message: req.message,
        requested_at: req.requested_at&.iso8601,
        evidence_id: req.evidence_id
      }
    end
  end
end
