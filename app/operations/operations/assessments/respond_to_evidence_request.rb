# frozen_string_literal: true

# Fulfils a pending evidence request by recording the requestee's evidence
# against the request's cell and marking the request responded. The evidence
# source is derived from the requestee↔assessee relationship (peer / manager).
#
# Write — :mcp_client. Same friction as recording evidence directly.
class Operations::Assessments::RespondToEvidenceRequest < Operations::Base
  description "Respond to an evidence request by providing the requested evidence."
  category :write
  approval :mcp_client

  parameter :request_id,    String, required: true
  parameter :evidence_type, String, required: true, allowed: EvidenceItem::EVIDENCE_TYPES
  parameter :content,       String, required: true
  parameter :custom_type_label, String
  parameter :title, String
  parameter :external_reference, Hash

  def policy_check
    raise Pundit::NotAuthorizedError, "not linked to a person" if context.person.nil?

    authorize evidence_request, :respond?, policy_class: EvidenceRequestPolicy
  end

  # @return [Hash] { request_id, status, evidence_id }
  def perform
    validate_type_label!
    validate_external_reference!

    evidence_id = SecureRandom.uuid_v7
    handler = PersonDevelopment::CommandHandler.new

    handler.record_evidence(
      evidence_request.person_id, evidence_request.framework_id, evidence_id,
      capability_stable_id: evidence_request.capability_stable_id,
      level_ordinal: evidence_request.level_ordinal,
      source: derive_source,
      evidence_type: params[:evidence_type],
      custom_type_label: params[:custom_type_label].presence,
      title: params[:title].presence,
      content: params[:content].to_s,
      author_id: context.person.id,
      external_reference: params[:external_reference]
    )
    handler.respond_to_evidence_request(
      evidence_request.person_id, evidence_request.framework_id, evidence_request.id,
      evidence_id: evidence_id, responded_by_id: context.person.id
    )

    { request_id: evidence_request.id, status: "responded", evidence_id: evidence_id }
  rescue PersonDevelopment::Aggregate::CommandError => e
    raise Operations::Base::ParameterError, e.message
  end

  private

  def evidence_request
    @evidence_request ||= EvidenceRequest.find(params[:request_id])
  end

  def derive_source
    assessee = Person.find_by(id: evidence_request.person_id)
    assessee&.managed_by?(context.person) ? "manager" : "peer"
  end

  def validate_type_label!
    return unless params[:evidence_type] == "other"
    return if params[:custom_type_label].present?

    raise Operations::Base::ParameterError, "custom_type_label is required when evidence_type is 'other'"
  end

  def validate_external_reference!
    return if params[:external_reference].blank?

    candidate = ExternalReference.new(params[:external_reference])
    return if candidate.valid?

    raise Operations::Base::ParameterError, "invalid external_reference: #{candidate.errors.full_messages.join(", ")}"
  end
end
