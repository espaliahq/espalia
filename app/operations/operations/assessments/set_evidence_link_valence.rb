# frozen_string_literal: true

# Reclassifies the valence of one of an evidence item's capability × level
# links — e.g. re-judging a "demonstrated" link a "growth_area", or
# classifying a pre-valence (nil) link for the first time. The link's
# identity and history are preserved (this is NOT a remove + re-add).
#
# A no-op when the link already carries the requested valence, so a
# full-state resubmit is safe. Reclassification is an explicit affordance:
# existing links are never force-reclassified by content edits.
#
# Write — :mcp_client approval. Same additive-context friction as adding
# a link; valence is narrative metadata, never a scoring input.
class Operations::Assessments::SetEvidenceLinkValence < Operations::Base
  description "Reclassify the valence of a feedback / evidence link (what the evidence says about the behaviour at that capability × level)."
  category :write
  approval :mcp_client

  parameter :assignment_id,        String, required: true
  parameter :evidence_id,          String, required: true
  parameter :capability_stable_id, String, required: true
  parameter :level_ordinal,        Integer, required: true
  parameter :valence, String, required: true, allowed: EvidenceLink::VALENCES

  def policy_check
    raise Pundit::NotAuthorizedError, "not linked to a person" if context.person.nil?

    # Same bar as adding a link — valence is an assertion about the
    # linkage, made by whoever may manage the item's links.
    authorize evidence_item, :add_link?, policy_class: EvidencePolicy
  end

  # @return [Hash] `{ evidence_id, capability_stable_id, level_ordinal,
  #   valence, links }` — the reclassified coordinate plus every active
  #   link the item carries.
  def perform
    PersonDevelopment::CommandHandler.new.set_evidence_link_valence(
      assignment.person_id, assignment.framework_id, params[:evidence_id],
      capability_stable_id: params[:capability_stable_id],
      level_ordinal: params[:level_ordinal],
      valence: params[:valence],
      changed_by_id: context.person.id
    )

    {
      evidence_id: params[:evidence_id],
      capability_stable_id: params[:capability_stable_id],
      level_ordinal: params[:level_ordinal],
      valence: params[:valence],
      links: active_links_for(params[:evidence_id])
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

  def active_links_for(evidence_id)
    EvidenceLink.active.where(evidence_id: evidence_id).order(:linked_at).map do |link|
      { capability_stable_id: link.capability_stable_id, level_ordinal: link.level_ordinal,
        valence: link.valence }
    end
  end
end
