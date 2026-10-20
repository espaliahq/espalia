# frozen_string_literal: true

# Places a piece of feedback where a placement suggestion said it belongs: the
# suggested capability × level, with the suggested valence or one the person
# chose instead. The resulting EvidenceLinkAdded (or, when someone linked that
# cell in the meantime, EvidenceLinkRevalenced) carries `via_suggestion_id`,
# so the feed and the audit trail say the person took a suggestion.
#
# Write — :mcp_client approval, the same friction as adding a link by hand;
# authorised by {EvidencePolicy#add_link?}.
class Operations::Assessments::AcceptEvidenceSuggestion < Operations::Base
  include Operations::Assessments::EvidenceSuggestion

  description "Accept a placement suggestion: link the feedback / evidence to the suggested capability × level. " \
              "Pass valence to place it with a different judgement than the one suggested; the decision is then " \
              "recorded as edited rather than accepted."
  category :write
  approval :mcp_client

  parameter :suggestion_id, String, required: true
  parameter :valence, String, allowed: EvidenceLink::VALENCES

  def policy_check
    raise Pundit::NotAuthorizedError, "not linked to a person" if context.person.nil?

    authorize evidence_item, :add_link?, policy_class: EvidencePolicy
  end

  # @return [Hash] the decided suggestion plus `links`, every active link the
  #   item now carries
  def perform
    # One transaction with the suggestion row locked: the link event and the
    # decision land together, and a concurrent accept or dismiss waits, then
    # finds the suggestion already decided.
    valence = EvidencePlacementSuggestion.transaction do
      suggestion.lock!
      ensure_pending!
      ensure_cell_still_exists!
      place(params[:valence] || suggestion.valence)
    end

    suggestion_payload(suggestion, capability_names([ suggestion ])).merge(valence: valence, links: active_links)
  rescue PersonDevelopment::Aggregate::CommandError => e
    raise Operations::Base::ParameterError, e.message
  end

  private

  # @return [String] the valence the item was placed with
  def place(valence)
    if linked?
      handler.set_evidence_link_valence(evidence_item.person_id, evidence_item.framework_id, evidence_item.id,
        capability_stable_id: suggestion.capability_stable_id, level_ordinal: suggestion.level_ordinal,
        valence: valence, changed_by_id: context.person.id, via_suggestion_id: suggestion.id)
    else
      handler.add_evidence_link(evidence_item.person_id, evidence_item.framework_id, evidence_item.id,
        capability_stable_id: suggestion.capability_stable_id, level_ordinal: suggestion.level_ordinal,
        linked_by_id: context.person.id, valence: valence, via_suggestion_id: suggestion.id)
    end
    suggestion.decide!(status: valence == suggestion.valence ? "accepted" : "edited", by: context.person)
    valence
  end

  def handler
    @handler ||= PersonDevelopment::CommandHandler.new
  end

  def linked?
    EvidenceLink.active.exists?(evidence_id: evidence_item.id, capability_stable_id: suggestion.capability_stable_id,
                                level_ordinal: suggestion.level_ordinal)
  end

  # The framework may have moved on since the suggestion was made: a
  # capability archived, a binding removed, the person moved role.
  def ensure_cell_still_exists!
    assignment = PersonFrameworkAssignment.find_by(person_id: evidence_item.person_id, framework_id: evidence_item.framework_id)
    map = assignment ? Evidence::FrameworkCellOptions.new(framework_id: assignment.framework_id, role_id: assignment.role_id).expectation_map : {}
    return if map.key?("#{suggestion.capability_stable_id}|#{suggestion.level_ordinal}")

    raise Operations::Base::ParameterError, "the suggested capability and level are no longer on this person's role"
  end

  def active_links
    EvidenceLink.active.where(evidence_id: evidence_item.id).order(:linked_at).map do |link|
      { capability_stable_id: link.capability_stable_id, level_ordinal: link.level_ordinal, valence: link.valence }
    end
  end
end
