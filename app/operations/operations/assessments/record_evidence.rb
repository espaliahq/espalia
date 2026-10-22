# frozen_string_literal: true

# Records a new piece of evidence on the named assignment — against one
# capability × level, or UNPLACED when the caller gives no cell: the
# recipient, their manager or the author places it later with
# `assessments_add_evidence_link`. Mirrors the web EvidenceController#create —
# same validations on type / custom label / external reference, same
# {EvidencePolicy#create?} authorisation, same {PersonDevelopment::CommandHandler#record_evidence}
# dispatch.
#
# `source` is derived from the relationship between the caller and the
# assessee (self / manager / peer) — never trusted from the input —
# through {EvidenceItem.source_for}.
#
# Write — :mcp_client approval. Evidence is additive (it adds context to
# the assessment, doesn't grant permissions or change other people's
# data); a manager evidencing a direct report is routine, and the MCP
# client's own write-approval prompt is the right friction.
class Operations::Assessments::RecordEvidence < Operations::Base
  description "Record a piece of feedback / evidence on an assessment — against a capability × level, or " \
              "with no cell at all when you don't know which expectation it speaks to: the recipient or their " \
              "manager places it later. Find a colleague's assignment_id with assessments_feedback_recipients."
  category :write
  approval :mcp_client
  prose_fields :content

  parameter :assignment_id,        String, required: true
  # A blank cell is a mistake, never "unplaced": omit the cell for that.
  parameter :capability_stable_id, String, allow_blank: false
  parameter :level_ordinal,        Integer
  parameter :evidence_type, String, required: true,
                                    allowed: EvidenceItem::EVIDENCE_TYPES
  parameter :custom_type_label, String
  parameter :title, String
  parameter :content, String, required: true
  # The origin link's valence — the recorder's judgment of what the
  # evidence says about the behaviour at that cell. Required with a cell;
  # narrative metadata only, never a scoring input.
  parameter :valence, String, allowed: EvidenceLink::VALENCES, allow_blank: false
  parameter :external_reference, Hash, schema: ExternalReference.json_schema
  # Optional extra cells this evidence also demonstrates. The first link is
  # the required capability_stable_id/level_ordinal/valence above; these
  # are applied atomically as additional links, each with its own valence.
  parameter :additional_links, Array, schema: {
    type: "array",
    items: {
      type: "object",
      properties: {
        capability_stable_id: { type: "string" },
        level_ordinal: { type: "integer" },
        valence: { type: "string", enum: EvidenceLink::VALENCES }
      },
      required: %w[capability_stable_id level_ordinal valence]
    }
  }

  # The read model requires a label for the 'other' type.
  requires_when :custom_type_label, if: :evidence_type, equals: "other"
  # A cell is both halves plus its valence, or nothing; extra links follow a
  # first one. The same rule the aggregate enforces, said in the schema.
  dependent_required :capability_stable_id, requires: :level_ordinal
  dependent_required :capability_stable_id, requires: :valence
  dependent_required :level_ordinal, requires: :capability_stable_id
  dependent_required :valence, requires: :capability_stable_id
  dependent_required :additional_links, requires: :capability_stable_id

  def policy_check
    raise Pundit::NotAuthorizedError, "not linked to a person" if context.person.nil?

    authorize assignment, :create?, policy_class: EvidencePolicy
  end

  # @return [Hash] `{ evidence_id, person_id, framework_id, placed,
  #   capability_stable_id, level_ordinal, evidence_type, source,
  #   recorded_at, links }` — the durable identifying fields plus the
  #   resolved `source` so the LLM can confirm how the system
  #   categorised the caller's relationship to the assessee, and `links`
  #   (every active `{ capability_stable_id, level_ordinal, valence }` the
  #   item is attached to — empty, with `placed: false`, for an unplaced item).
  def perform
    validate_external_reference!
    if placed?
      validate_level_ordinal!
      validate_capability_in_framework!(params[:capability_stable_id])
    end
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
      valence: params[:valence],
      external_reference: params[:external_reference],
      additional_links: additional_links
    )

    item = EvidenceItem.find(evidence_id)
    {
      evidence_id: item.id,
      person_id: item.person_id,
      framework_id: item.framework_id,
      placed: placed?,
      capability_stable_id: item.capability_stable_id,
      level_ordinal: item.level_ordinal,
      evidence_type: item.evidence_type,
      source: item.source,
      recorded_at: item.recorded_at.iso8601,
      links: EvidenceLink.active.where(evidence_id: item.id).order(:linked_at).map do |link|
        { capability_stable_id: link.capability_stable_id, level_ordinal: link.level_ordinal,
          valence: link.valence }
      end
    }
  rescue PersonDevelopment::Aggregate::CommandError => e
    raise Operations::Base::ParameterError, e.message
  end

  private

  def assignment
    @assignment ||= PersonFrameworkAssignment.find(params[:assignment_id])
  end

  def placed?
    params[:capability_stable_id].present?
  end

  # Coerces + validates the optional additional_links param into the
  # { capability_stable_id:, level_ordinal:, valence: } shape the command
  # handler expects, validating each level_ordinal against the
  # assignment's role and each valence against the allowed set.
  def normalize_additional_links!
    raw = params[:additional_links]
    return [] if raw.blank?

    raw.map do |entry|
      entry = entry.to_h if entry.respond_to?(:to_h)
      cap = entry["capability_stable_id"] || entry[:capability_stable_id]
      level = entry["level_ordinal"] || entry[:level_ordinal]
      valence = entry["valence"] || entry[:valence]
      if cap.blank? || level.blank?
        raise Operations::Base::ParameterError,
          "each additional_links entry needs capability_stable_id and level_ordinal"
      end
      unless EvidenceLink::VALENCES.include?(valence)
        raise Operations::Base::ParameterError,
          "each additional_links entry needs a valence (one of: #{EvidenceLink::VALENCES.join(', ')})"
      end
      level = Integer(level, exception: false)
      validate_level_ordinal!(level)
      validate_capability_in_framework!(cap)
      { capability_stable_id: cap, level_ordinal: level, valence: valence }
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

  # The external reference URL is validated upfront — same posture as
  # the web controller — so a `javascript:` URL or similar XSS vector
  # never lands in the event stream and can't fail on replay.
  def validate_external_reference!
    reason = ExternalReference.validation_error_for(params[:external_reference])
    return unless reason

    raise Operations::Base::ParameterError, "invalid external_reference: #{reason}"
  end

  def validate_level_ordinal!(ordinal = params[:level_ordinal])
    exists = FrameworkState::Level.exists?(
      role_id: assignment.role_id, ordinal: ordinal
    )
    return if exists

    raise Operations::Base::ParameterError,
      "level_ordinal #{ordinal} does not exist for the assignment's role"
  end

  def derive_source
    EvidenceItem.source_for(author: context.person, recipient: Person.find_by(id: assignment.person_id))
  end
end
