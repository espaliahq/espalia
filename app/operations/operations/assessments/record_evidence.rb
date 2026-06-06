# frozen_string_literal: true

# Records a new piece of evidence against one capability × level on the
# named assignment. Mirrors the web EvidenceController#create — same
# validations on type / custom label / external reference, same
# {EvidencePolicy#create?} authorisation, same {PersonDevelopment::CommandHandler#record_evidence}
# dispatch.
#
# `source` is derived from the relationship between the caller and the
# assessee (self / manager / peer) — never trusted from the input —
# matching `infer_source` on the controller.
#
# Write — :mcp_client approval. Evidence is additive (it adds context to
# the assessment, doesn't grant permissions or change other people's
# data); a manager evidencing a direct report is routine, and the MCP
# client's own write-approval prompt is the right friction.
class Operations::Assessments::RecordEvidence < Operations::Base
  description "Record a piece of evidence against a capability × level on an assessment."
  category :write
  approval :mcp_client

  parameter :assignment_id,        String, required: true
  parameter :capability_stable_id, String, required: true
  parameter :level_ordinal,        Integer, required: true
  parameter :evidence_type, String, required: true,
                                    allowed: EvidenceItem::EVIDENCE_TYPES
  parameter :custom_type_label, String   # required when evidence_type == "other"
  parameter :title, String
  parameter :content, String, required: true
  parameter :external_reference, Hash    # { system:, url:, external_id: }
  # Optional extra cells this evidence also demonstrates. Each entry:
  # { capability_stable_id:, level_ordinal: }. The first link is the
  # required capability_stable_id/level_ordinal above; these are applied
  # atomically as additional links.
  parameter :additional_links, Array

  def policy_check
    raise Pundit::NotAuthorizedError, "not linked to a person" if context.person.nil?

    authorize assignment, :create?, policy_class: EvidencePolicy
  end

  # @return [Hash] `{ evidence_id, person_id, framework_id,
  #   capability_stable_id, level_ordinal, evidence_type, source,
  #   recorded_at, links }` — the durable identifying fields plus the
  #   resolved `source` so the LLM can confirm how the system
  #   categorised the caller's relationship to the assessee, and `links`
  #   (every active `{ capability_stable_id, level_ordinal }` the item is
  #   attached to).
  def perform
    validate_evidence_type_label!
    validate_external_reference!
    validate_level_ordinal!
    validate_capability_in_framework!(params[:capability_stable_id])
    additional_links = normalize_additional_links!

    evidence_id = SecureRandom.uuid_v7
    source = derive_source

    PersonDevelopment::CommandHandler.new.record_evidence(
      assignment.person_id, assignment.framework_id, evidence_id,
      capability_stable_id: params[:capability_stable_id],
      level_ordinal: params[:level_ordinal],
      source: source,
      evidence_type: params[:evidence_type],
      custom_type_label: params[:custom_type_label].presence,
      title: params[:title].presence,
      content: params[:content].to_s,
      author_id: context.person.id,
      external_reference: params[:external_reference],
      additional_links: additional_links
    )

    item = EvidenceItem.find(evidence_id)
    {
      evidence_id: item.id,
      person_id: item.person_id,
      framework_id: item.framework_id,
      capability_stable_id: item.capability_stable_id,
      level_ordinal: item.level_ordinal,
      evidence_type: item.evidence_type,
      source: item.source,
      recorded_at: item.recorded_at.iso8601,
      links: EvidenceLink.active.where(evidence_id: item.id).order(:linked_at).map do |link|
        { capability_stable_id: link.capability_stable_id, level_ordinal: link.level_ordinal }
      end
    }
  rescue PersonDevelopment::Aggregate::CommandError => e
    raise Operations::Base::ParameterError, e.message
  end

  private

  def assignment
    @assignment ||= PersonFrameworkAssignment.find(params[:assignment_id])
  end

  # Coerces + validates the optional additional_links param into the
  # { capability_stable_id:, level_ordinal: } shape the command handler
  # expects, validating each level_ordinal against the assignment's role.
  def normalize_additional_links!
    raw = params[:additional_links]
    return [] if raw.blank?

    raw.map do |entry|
      entry = entry.to_h if entry.respond_to?(:to_h)
      cap = entry["capability_stable_id"] || entry[:capability_stable_id]
      level = entry["level_ordinal"] || entry[:level_ordinal]
      if cap.blank? || level.blank?
        raise Operations::Base::ParameterError,
          "each additional_links entry needs capability_stable_id and level_ordinal"
      end
      level = Integer(level, exception: false)
      validate_level_ordinal!(level)
      validate_capability_in_framework!(cap)
      { capability_stable_id: cap, level_ordinal: level }
    end
  end

  # Guards against recording/linking evidence onto a capability outside this
  # assessment's framework (the lookup is scoped to the assignment's
  # framework, so a foreign / non-existent stable_id resolves to absent).
  def validate_capability_in_framework!(capability_stable_id)
    in_framework = FrameworkState::Capability
      .joins(:category)
      .where(stable_id: capability_stable_id)
      .merge(FrameworkState::CapabilityCategory.where(framework_id: assignment.framework_id))
      .exists?
    return if in_framework

    raise Operations::Base::ParameterError,
      "capability_stable_id does not belong to the assignment's framework"
  end

  # The 'other' evidence_type carries a free-text label; the read model
  # requires it. Reject upfront with ParameterError so the failure maps
  # to JSON-RPC -32602 rather than a generic command-handler raise.
  def validate_evidence_type_label!
    return unless params[:evidence_type] == "other"

    if params[:custom_type_label].blank?
      raise Operations::Base::ParameterError, "custom_type_label is required when evidence_type is 'other'"
    end
  end

  # The external reference URL is validated upfront — same posture as
  # the web controller — so a `javascript:` URL or similar XSS vector
  # never lands in the event stream and can't fail on replay.
  def validate_external_reference!
    return if params[:external_reference].blank?

    candidate = ExternalReference.new(params[:external_reference])
    return if candidate.valid?

    raise Operations::Base::ParameterError, "invalid external_reference: #{candidate.errors.full_messages.join(", ")}"
  end

  def validate_level_ordinal!(ordinal = params[:level_ordinal])
    exists = FrameworkState::Level.exists?(
      role_id: assignment.role_id, ordinal: ordinal
    )
    return if exists

    raise Operations::Base::ParameterError,
      "level_ordinal #{ordinal} does not exist for the assignment's role"
  end

  # Same logic as EvidenceController#infer_source — derived from the
  # actor↔assessee relationship, never trusted from input.
  def derive_source
    assessee = Person.find_by(id: assignment.person_id)
    return "self" if assessee&.id == context.person.id
    return "manager" if assessee&.managed_by?(context.person)

    "peer"
  end
end
