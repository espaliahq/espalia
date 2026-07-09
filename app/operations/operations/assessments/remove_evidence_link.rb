# frozen_string_literal: true

# Removes one of an evidence item's capability × level links on the named
# assignment. The item stops appearing in that cell but keeps its other
# links. Mirrors the web EvidenceController#remove_link: same
# {EvidencePolicy#remove_link?} authorisation and
# {PersonDevelopment::CommandHandler#remove_evidence_link} dispatch.
#
# An active evidence item must always retain at least one link — removing
# the last link is rejected (withdraw the item instead). That domain
# invariant surfaces here as a ParameterError.
#
# Write — :mcp_client approval. Removing a link is a reversible, additive-
# scope change (re-add the link to undo); the same friction as recording
# evidence is appropriate.
class Operations::Assessments::RemoveEvidenceLink < Operations::Base
  description "Remove one capability × level link from a feedback / evidence item (it keeps its other links)."
  category :write
  approval :mcp_client

  parameter :assignment_id,        String, required: true
  parameter :evidence_id,          String, required: true
  parameter :capability_stable_id, String, required: true
  parameter :level_ordinal,        Integer, required: true
  parameter :reason, String

  def policy_check
    raise Pundit::NotAuthorizedError, "not linked to a person" if context.person.nil?

    authorize evidence_item, :remove_link?, policy_class: EvidencePolicy
  end

  # @return [Hash] `{ evidence_id, capability_stable_id, level_ordinal,
  #   links }` — the removed coordinate plus the active links that remain.
  def perform
    PersonDevelopment::CommandHandler.new.remove_evidence_link(
      assignment.person_id, assignment.framework_id, params[:evidence_id],
      capability_stable_id: params[:capability_stable_id],
      level_ordinal: params[:level_ordinal],
      removed_by_id: context.person.id,
      reason: params[:reason].presence
    )

    {
      evidence_id: params[:evidence_id],
      capability_stable_id: params[:capability_stable_id],
      level_ordinal: params[:level_ordinal],
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
