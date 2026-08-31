# frozen_string_literal: true

# Fulfils a pending evidence request by recording the requestee's evidence
# against the request's cell and marking the request responded. The evidence
# source is derived from the requestee↔assessee relationship (peer / manager).
#
# Write — :mcp_client. Same friction as recording evidence directly.
class Operations::Assessments::RespondToEvidenceRequest < Operations::Base
  description "Respond to a feedback / evidence request by providing the requested feedback."
  category :write
  approval :mcp_client

  parameter :request_id,    String, required: true
  parameter :evidence_type, String, required: true, allowed: EvidenceItem::EVIDENCE_TYPES
  parameter :content,       String, required: true
  # The responder's judgment of what their feedback says about the
  # requested behaviour. Required; narrative metadata only, never a
  # scoring input.
  parameter :valence, String, required: true, allowed: EvidenceLink::VALENCES
  parameter :custom_type_label, String
  parameter :title, String
  parameter :external_reference, Hash, schema: ExternalReference.json_schema

  # The 'other' evidence_type carries a free-text label the read model
  # requires — advertised as well as enforced, so a client can obey it.
  requires_when :custom_type_label, if: :evidence_type, equals: "other"

  def policy_check
    raise Pundit::NotAuthorizedError, "not linked to a person" if context.person.nil?

    authorize evidence_request, :respond?, policy_class: EvidenceRequestPolicy
  end

  # @return [Hash] { request_id, status, evidence_id }
  def perform
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
      valence: params[:valence],
      external_reference: params[:external_reference],
      cycle_id: evidence_request.cycle_id
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

  def validate_external_reference!
    reason = ExternalReference.validation_error_for(params[:external_reference])
    return unless reason

    raise Operations::Base::ParameterError, "invalid external_reference: #{reason}"
  end
end
