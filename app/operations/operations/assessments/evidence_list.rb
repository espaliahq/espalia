# frozen_string_literal: true

# Lists the active evidence attached to one capability on an assessment —
# the read drill-in that closes the assessment → capability → evidence
# traversal. Optionally narrows to a single capability × level cell. With
# no capability it lists the UNPLACED items instead: feedback recorded
# without a cell, waiting for someone to place it.
#
# Evidence content lives on {EvidenceItem}; the (capability, level)
# coordinates an item demonstrates live on {EvidenceLink} (one item can
# evidence several cells). This reads the links for the requested scope,
# then loads the items, mirroring `Assessments::EvidenceController#evidence_items_for`.
#
# Read-only; scoped by {EvidencePolicy#index?} (assessee + their manager
# chain + active rating delegate + tenant admin). That set is exactly the
# set that may see ALL of the assessee's evidence, so no per-author
# filtering is needed here — anyone who passes the policy sees every
# active item. Withdrawn items and removed links are omitted (matching the
# matrix's `.active` scope).
class Operations::Assessments::EvidenceList < Operations::Base
  description "List active feedback / evidence on an assessment for one capability (optionally one level), " \
              "or — with no capability — the unplaced items still waiting to be placed on one. " \
              "Accepts either capability_id (version-specific) or stable_id (cross-version) in " \
              "the capability_stable_id argument. Each item carries its full set of linked cells."
  category :read
  approval :none

  parameter :assignment_id,        String, required: true
  # Omitted means "the unplaced items"; blank is a mistake, as in record_evidence.
  parameter :capability_stable_id, String, allow_blank: false
  parameter :level_ordinal,        Integer

  dependent_required :level_ordinal, requires: :capability_stable_id

  def policy_check
    authorize assignment, :index?, policy_class: EvidencePolicy
  end

  # @return [Hash] `{ capability_stable_id:, level_ordinal:, unplaced:, evidence: [...] }`
  #   — `unplaced: true` (and nil coordinates) when listing the items with no
  #   cell yet — where each evidence entry carries `{ evidence_id, evidence_type,
  #   custom_type_label, title, content, source, author{id,name},
  #   external_reference|nil, recorded_at, edited_at|nil, links[] }`. `links`
  #   is every active `{ capability_stable_id, level_ordinal, valence }` the item is
  #   attached to — so a multi-linked item shows where else it counts.
  def perform
    found = items
    links_by_evidence = active_links_for(found.map(&:id))

    {
      capability_stable_id: unplaced? ? nil : capability.stable_id,
      level_ordinal: params[:level_ordinal],
      unplaced: unplaced?,
      evidence: found.map { |item| item_payload(item, links_by_evidence[item.id] || []) }
    }
  end

  private

  def assignment
    @assignment ||= PersonFrameworkAssignment.find(params[:assignment_id])
  end

  def unplaced?
    params[:capability_stable_id].nil?
  end

  # Resolve the capability within the assignment's framework, accepting
  # either the version-specific capability_id or the cross-version
  # stable_id (LLM clients pass whichever they have). Scoping the lookup
  # to the framework prevents requesting a capability from a sibling
  # framework in the same tenant (see mcp-server.md Hard-Won Lesson 5).
  def capability
    @capability ||= begin
      scope = FrameworkState::Capability
        .joins(:category)
        .where(framework_capability_categories: { framework_id: assignment.framework_id })
      identifier = params[:capability_stable_id]
      scope.find_by(stable_id: identifier) || scope.find_by!(capability_id: identifier)
    end
  end

  # Items with an active link in the requested scope, ordered by when they
  # were recorded. Driven off {EvidenceLink} (an item appears in a cell
  # because it has an active link there), not the item's origin columns.
  def items
    if unplaced?
      return EvidenceItem.unplaced.for_person(assignment.person_id).for_framework(assignment.framework_id)
        .includes(:author).order(:recorded_at).to_a
    end

    links = EvidenceLink.active
      .for_person(assignment.person_id)
      .for_framework(assignment.framework_id)
      .for_capability(capability.stable_id)
    links = links.at_level(params[:level_ordinal]) if params[:level_ordinal]

    item_ids = links.distinct.pluck(:evidence_id)
    return [] if item_ids.empty?

    EvidenceItem.active.where(id: item_ids).includes(:author).order(:recorded_at).to_a
  end

  def item_payload(item, links)
    {
      evidence_id: item.id,
      evidence_type: item.evidence_type,
      custom_type_label: item.custom_type_label,
      title: item.title,
      content: item.content,
      source: item.source,
      author: { id: item.author_id, name: item.author&.name },
      external_reference: external_reference_payload(item),
      recorded_at: item.recorded_at&.iso8601,
      edited_at: item.edited_at&.iso8601,
      links: links.map { |link|
        { capability_stable_id: link.capability_stable_id, level_ordinal: link.level_ordinal,
          valence: link.valence }
      }
    }
  end

  # All active links for the given items, grouped by evidence_id and ordered
  # by link time — one query for the whole set rather than one per item.
  def active_links_for(evidence_ids)
    return {} if evidence_ids.empty?

    EvidenceLink.active.where(evidence_id: evidence_ids).order(:linked_at).group_by(&:evidence_id)
  end

  # The StoreModel is always present (defaults to a blank instance); only
  # surface it when it actually carries a reference so the payload stays
  # quiet for the common no-reference case.
  def external_reference_payload(item)
    ref = item.external_reference
    return nil if ref.blank? || (ref.url.blank? && ref.external_id.blank? && ref.system.blank?)

    { system: ref.system, url: ref.url, external_id: ref.external_id }
  end
end
