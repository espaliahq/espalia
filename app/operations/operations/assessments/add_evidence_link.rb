# frozen_string_literal: true

# Links an existing evidence item to an additional capability × level on
# the named assignment — one piece of evidence can demonstrate several
# expectations. Mirrors the web EvidenceController#add_link: same
# {EvidencePolicy#add_link?} authorisation and
# {PersonDevelopment::CommandHandler#add_evidence_link} dispatch.
#
# Write — :mcp_client approval. Linking is additive context (it doesn't
# grant permissions or change other people's data); the same friction as
# recording evidence is appropriate.
class Operations::Assessments::AddEvidenceLink < Operations::Base
  description "Link an existing feedback / evidence item to an additional capability × level."
  category :write
  approval :mcp_client

  parameter :assignment_id,        String, required: true
  parameter :evidence_id,          String, required: true
  parameter :capability_stable_id, String, required: true
  parameter :level_ordinal,        Integer, required: true
  # The linker's judgment of what the evidence says about the behaviour at
  # this cell. Required on every new link; narrative metadata only, never
  # a scoring input.
  parameter :valence, String, required: true, allowed: EvidenceLink::VALENCES
  parameter :rationale, String

  def policy_check
    raise Pundit::NotAuthorizedError, "not linked to a person" if context.person.nil?

    authorize evidence_item, :add_link?, policy_class: EvidencePolicy
  end

  # @return [Hash] `{ evidence_id, capability_stable_id, level_ordinal,
  #   links }` — the new link plus every active link the item now carries.
  def perform
    validate_level_ordinal!
    validate_capability_in_framework!(params[:capability_stable_id])

    PersonDevelopment::CommandHandler.new.add_evidence_link(
      assignment.person_id, assignment.framework_id, params[:evidence_id],
      capability_stable_id: params[:capability_stable_id],
      level_ordinal: params[:level_ordinal],
      linked_by_id: context.person.id,
      valence: params[:valence],
      rationale: params[:rationale].presence
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

  def validate_level_ordinal!
    return if FrameworkState::Level.exists?(role_id: assignment.role_id, ordinal: params[:level_ordinal])

    raise Operations::Base::ParameterError,
      "level_ordinal #{params[:level_ordinal]} does not exist for the assignment's role"
  end

  # Guards against linking to a capability outside this assessment's
  # framework — without this an attacker authorised for framework A could
  # persist a link onto a capability_stable_id from framework B (the lookup
  # is scoped to the assignment's framework, so a foreign id resolves to nil).
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

  def active_links_for(evidence_id)
    EvidenceLink.active.where(evidence_id: evidence_id).order(:linked_at).map do |link|
      { capability_stable_id: link.capability_stable_id, level_ordinal: link.level_ordinal,
        valence: link.valence }
    end
  end
end
