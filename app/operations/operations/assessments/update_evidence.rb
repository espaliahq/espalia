# frozen_string_literal: true

# Edits the user-correctable content of an existing evidence item — type,
# label, title, body, external reference. Mirrors the web
# EvidenceController#update: same {EvidencePolicy#update?} authorisation
# (author-only, not withdrawn) and
# {PersonDevelopment::CommandHandler#update_evidence} dispatch.
#
# The update replaces the editable fields wholesale (it is not a patch), so
# callers must supply the full intended content — matching the web form,
# which submits every field. Capability × level links are NOT touched here;
# use add/remove_evidence_link for those.
#
# Write — :mcp_client approval. Correcting your own evidence is a routine,
# reversible, author-scoped change; the same friction as recording it.
class Operations::Assessments::UpdateEvidence < Operations::Base
  description "Edit an existing feedback / evidence item's type, title, content, and external reference."
  category :write
  approval :mcp_client

  parameter :assignment_id, String, required: true
  parameter :evidence_id,   String, required: true
  parameter :evidence_type, String, required: true,
                                    allowed: EvidenceItem::EVIDENCE_TYPES
  parameter :custom_type_label, String # required when evidence_type == "other"
  parameter :title, String
  parameter :content, String, required: true
  parameter :external_reference, Hash, schema: ExternalReference.json_schema

  def policy_check
    raise Pundit::NotAuthorizedError, "not linked to a person" if context.person.nil?

    authorize evidence_item, :update?, policy_class: EvidencePolicy
  end

  # @return [Hash] `{ evidence_id, evidence_type, custom_type_label, title,
  #   content, external_reference|nil, edited_at }` — the item's editable
  #   fields after the update.
  def perform
    validate_evidence_type_label!
    validate_external_reference!

    PersonDevelopment::CommandHandler.new.update_evidence(
      assignment.person_id, assignment.framework_id, params[:evidence_id],
      title: params[:title].presence,
      content: params[:content].to_s,
      evidence_type: params[:evidence_type],
      custom_type_label: params[:custom_type_label].presence,
      external_reference: params[:external_reference],
      edited_by_id: context.person.id
    )

    item = EvidenceItem.find(params[:evidence_id])
    {
      evidence_id: item.id,
      evidence_type: item.evidence_type,
      custom_type_label: item.custom_type_label,
      title: item.title,
      content: item.content,
      external_reference: external_reference_payload(item),
      edited_at: item.edited_at&.iso8601
    }
  rescue PersonDevelopment::Aggregate::CommandError => e
    raise Operations::Base::ParameterError, e.message
  end

  private

  def assignment
    @assignment ||= PersonFrameworkAssignment.find(params[:assignment_id])
  end

  def evidence_item
    @evidence_item ||= EvidenceItem.find(params[:evidence_id])
  end

  # The 'other' evidence_type carries a free-text label the read model
  # requires. Reject upfront so the failure maps to JSON-RPC -32602.
  def validate_evidence_type_label!
    return unless params[:evidence_type] == "other"
    return if params[:custom_type_label].present?

    raise Operations::Base::ParameterError, "custom_type_label is required when evidence_type is 'other'"
  end

  # Reject a malformed / unsafe external reference upfront — same posture as
  # the web controller — so a `javascript:` URL never lands in the stream.
  def validate_external_reference!
    reason = ExternalReference.validation_error_for(params[:external_reference])
    return unless reason

    raise Operations::Base::ParameterError, "invalid external_reference: #{reason}"
  end

  def external_reference_payload(item)
    ref = item.external_reference
    return nil if ref.blank? || (ref.url.blank? && ref.external_id.blank? && ref.system.blank?)

    { system: ref.system, url: ref.url, external_id: ref.external_id }
  end
end
