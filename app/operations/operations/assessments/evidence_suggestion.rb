# frozen_string_literal: true

# What the suggestion Operations share: finding a suggestion, the item it is
# about, and the payload every one of them returns.
module Operations::Assessments::EvidenceSuggestion
  private

  def suggestion
    @suggestion ||= EvidencePlacementSuggestion.find(params[:suggestion_id])
  end

  def evidence_item
    @evidence_item ||= EvidenceItem.find(suggestion.evidence_id)
  end

  def ensure_pending!
    return if suggestion.pending?

    raise Operations::Base::ParameterError, "this suggestion was already #{suggestion.status}"
  end

  # @param row [EvidencePlacementSuggestion]
  # @param names [Hash{String => String}] capability stable_id => name
  # @return [Hash]
  def suggestion_payload(row, names)
    {
      suggestion_id: row.id, evidence_id: row.evidence_id,
      capability_stable_id: row.capability_stable_id, capability_name: names[row.capability_stable_id],
      level_ordinal: row.level_ordinal, valence: row.valence, confidence: row.confidence.to_f,
      rationale: row.rationale, status: row.status, dismiss_reason: row.dismiss_reason,
      model: row.model, prompt_version: row.prompt_version, generated_at: row.generated_at&.iso8601
    }
  end

  def capability_names(rows)
    FrameworkState::Capability.where(stable_id: rows.map(&:capability_stable_id).uniq, status: "active")
      .pluck(:stable_id, :name).to_h
  end
end
