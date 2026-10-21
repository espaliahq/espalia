# frozen_string_literal: true

# Shared "save evidence" reconciliation for the unified modal. The modal posts
# the FULL desired state (content fields + the complete set of desired link
# cells + optional request_id); this computes the diff against current state and
# emits only the minimal commands via the existing Operations (each authorizes
# via EvidencePolicy and dispatches through the command handler, preserving the
# activity-feed broadcast).
#
# Key rule: a links-only change must NOT emit UpdateEvidence (no spurious
# `edited_at` bump). Content fields disabled for a non-author aren't submitted,
# so the diff naturally finds no content change and only link commands fire.
#
# Returns the set of touched cells (for the assessment surface's Turbo-Stream
# response); the hub surface ignores it and redirects.
module EvidenceDiffSubmit
  extend ActiveSupport::Concern

  TouchedCells = Struct.new(:cells, :evidence_id)

  private

  # @return [TouchedCells]
  def apply_evidence_diff
    params_hash = evidence_diff_params
    case evidence_diff_mode(params_hash)
    when :respond then diff_respond(params_hash)
    when :edit    then diff_edit(params_hash)
    else               diff_new(params_hash)
    end
  end

  def evidence_diff_params
    params.expect(evidence: [ :assignment_id, :evidence_id, :request_id, :primary_cell,
                              :evidence_type, :custom_type_label, :title, :content,
                              { external_reference: [ :system, :url ] }, { desired_links: [] },
                              { link_valences: {} }, { suggestion_ids: [] }, { staged_suggestion_ids: [] } ])
      .to_h.symbolize_keys
  end

  def evidence_diff_mode(p)
    return :respond if p[:request_id].present?
    return :edit if p[:evidence_id].present?

    :new
  end

  # ── Modes ──

  # The seed cell is the first link when the form had one; a volunteered
  # form has none, so the first staged row leads — or, with no rows at all,
  # the item is recorded unplaced.
  def diff_new(p)
    cells = desired_cells(p)
    primary = parse_cell(p[:primary_cell]) || cells.first
    if p[:primary_cell].present? && parse_cell(p[:primary_cell]).nil?
      raise Operations::Base::ParameterError, "Missing or malformed primary cell"
    end
    if primary.nil?
      result = Operations::Assessments::RecordEvidence.call(context: pundit_user, params: {
        assignment_id: p[:assignment_id], **content_params(p)
      })
      return TouchedCells.new([], result[:evidence_id])
    end

    valences = link_valences(p)
    extras = cells - [ primary ]

    result = Operations::Assessments::RecordEvidence.call(context: pundit_user, params: {
      assignment_id: p[:assignment_id],
      capability_stable_id: primary.first, level_ordinal: primary.last,
      valence: valence_for!(valences, primary),
      additional_links: extras.map do |cap, level|
        { capability_stable_id: cap, level_ordinal: level, valence: valence_for!(valences, [ cap, level ]) }
      end,
      **content_params(p)
    })
    TouchedCells.new(cells, result[:evidence_id])
  end

  def diff_respond(p)
    request = EvidenceRequest.find(p[:request_id])
    assignment_id = assignment_id_for(request)
    primary = [ request.capability_stable_id, request.level_ordinal ]
    valences = link_valences(p)
    extras = desired_cells(p) - [ primary ]
    # Validate every new link's valence BEFORE any write — otherwise a
    # missing valence on cell N would abort after cells 1..N-1 (and the
    # response itself) had already landed.
    ([ primary ] + extras).each { |cell| valence_for!(valences, cell) }

    result = Operations::Assessments::RespondToEvidenceRequest.call(context: pundit_user, params: {
      request_id: request.id, valence: valences[primary], **content_params(p)
    })
    evidence_id = result[:evidence_id]
    extras.each do |cap, level|
      Operations::Assessments::AddEvidenceLink.call(context: pundit_user, params: {
        assignment_id: assignment_id, evidence_id: evidence_id, capability_stable_id: cap, level_ordinal: level,
        valence: valences[[ cap, level ]]
      })
    end
    TouchedCells.new(desired_cells(p), evidence_id)
  end

  def diff_edit(p)
    item = EvidenceItem.find(p[:evidence_id])
    assignment_id = assignment_id_for(item)
    current = EvidenceLink.active.where(evidence_id: item.id)
      .pluck(:capability_stable_id, :level_ordinal, :valence)
    current_cells = current.map { |cap, level, _| [ cap, level ] }.to_set
    current_valences = current.to_h { |cap, level, valence| [ [ cap, level ], valence ] }
    desired = desired_cells(p).to_set
    valences = link_valences(p)

    # Validate every new link's valence BEFORE any write (incl. the content
    # update) — a missing valence must reject the whole submit, not leave a
    # partially-applied diff behind.
    new_cells = desired - current_cells
    new_cells.each { |cell| valence_for!(valences, cell) }
    kept_suggestions = staged_suggestions(item, p[:suggestion_ids])
    ensure_staged_cells_exist!(item, kept_suggestions)

    if content_changed?(item, p)
      Operations::Assessments::UpdateEvidence.call(context: pundit_user, params: {
        assignment_id: assignment_id, evidence_id: item.id, **content_params(p, item)
      })
    end
    new_cells.each do |cap, level|
      if (suggestion = kept_suggestions[[ cap, level ]])
        accept_adjusted(suggestion, valences[[ cap, level ]])
      else
        Operations::Assessments::AddEvidenceLink.call(context: pundit_user, params: {
          assignment_id: assignment_id, evidence_id: item.id, capability_stable_id: cap, level_ordinal: level,
          valence: valences[[ cap, level ]]
        })
      end
    end
    (current_cells - desired).each do |cap, level|
      Operations::Assessments::RemoveEvidenceLink.call(context: pundit_user, params: {
        assignment_id: assignment_id, evidence_id: item.id, capability_stable_id: cap, level_ordinal: level
      })
    end
    # Kept links whose submitted judgment differs get reclassified. A blank
    # submission (pre-valence link left unclassified) is not a change —
    # existing links are never force-reclassified.
    (desired & current_cells).each do |cap, level|
      valence = valences[[ cap, level ]]
      # A staged suggestion on a cell someone linked meanwhile is still the
      # person's decision; accepting it reclassifies the link if they changed it.
      if (suggestion = kept_suggestions[[ cap, level ]])
        accept_adjusted(suggestion, valence || current_valences[[ cap, level ]])
        next
      end
      next if valence.nil? || valence == current_valences[[ cap, level ]]

      Operations::Assessments::SetEvidenceLinkValence.call(context: pundit_user, params: {
        assignment_id: assignment_id, evidence_id: item.id, capability_stable_id: cap, level_ordinal: level,
        valence: valence
      })
    end
    dismiss_removed_suggestions(item, p[:staged_suggestion_ids], kept_suggestions)
    TouchedCells.new((desired | current_cells).to_a, item.id)
  end

  # The pending suggestions "Adjust" staged whose rows survived the edit,
  # keyed by cell.
  #
  # @return [Hash{Array(String, Integer) => EvidencePlacementSuggestion}]
  def staged_suggestions(item, ids)
    return {} if ids.blank?

    EvidencePlacementSuggestion.pending.for_evidence(item.id).where(id: ids).index_by(&:cell)
  end

  # A suggestion kept through "Adjust" is accepted, attributed, and recorded
  # as edited: the person reviewed it in the editor, whatever valence they
  # left on it.
  def accept_adjusted(suggestion, valence)
    Operations::Assessments::AcceptEvidenceSuggestion.call(context: pundit_user, params: {
      suggestion_id: suggestion.id, valence: valence
    })
    EvidencePlacementSuggestion.where(id: suggestion.id, status: "accepted").update_all(status: "edited", updated_at: Time.current)
  end

  # Checked before any write, like the valences: the framework may have
  # dropped a staged cell since the suggestion was made, and failing on it
  # halfway would leave the save half-applied.
  def ensure_staged_cells_exist!(item, kept)
    return if kept.empty?

    assignment = PersonFrameworkAssignment.find_by!(person_id: item.person_id, framework_id: item.framework_id)
    map = Evidence::FrameworkCellOptions.new(framework_id: assignment.framework_id, role_id: assignment.role_id).expectation_map
    gone = kept.keys.reject { |cap, level| map.key?("#{cap}|#{level}") }
    return if gone.empty?

    raise Operations::Base::ParameterError, "A suggested capability and level are no longer on this person's role; remove that row and save again"
  end

  # A staged suggestion whose row the person removed before saving was
  # turned down.
  def dismiss_removed_suggestions(item, staged_ids, kept)
    removed = Array(staged_ids) - kept.values.map(&:id)
    return if removed.empty?

    EvidencePlacementSuggestion.pending.for_evidence(item.id).where(id: removed).find_each do |suggestion|
      Operations::Assessments::DismissEvidenceSuggestion.call(context: pundit_user, params: {
        suggestion_id: suggestion.id, reason: "Removed while adjusting"
      })
    end
  end

  # ── Helpers ──

  def desired_cells(p)
    Array(p[:desired_links]).filter_map { |token| parse_cell(token) }.uniq
  end

  # The submitted per-link judgments, keyed by [cap, level]. Blank values
  # (a pre-valence link left unclassified) are dropped.
  def link_valences(p)
    (p[:link_valences] || {}).each_with_object({}) do |(token, valence), acc|
      cell = parse_cell(token)
      acc[cell] = valence if cell && valence.present?
    end
  end

  # Every NEW link must carry a judgment — the modal enforces this
  # client-side (required controls); this is the server backstop, ahead of
  # the aggregate's own validation.
  def valence_for!(valences, cell)
    valences[cell] or raise Operations::Base::ParameterError,
      "Select what the feedback says about each linked behaviour"
  end

  def parse_cell(token)
    cap, level = token.to_s.split("|", 2)
    return nil if cap.blank? || level !~ /\A\d+\z/

    [ cap, level.to_i ]
  end

  # Content attrs for the record/update/respond ops; external_reference dropped
  # when its URL is blank. An item imported from a peer keeps its reference:
  # the form offers no fields for it, and where it was given is not the
  # editor's to change.
  def content_params(p, item = nil)
    attrs = {
      evidence_type: p[:evidence_type], content: p[:content].to_s,
      custom_type_label: p[:custom_type_label].presence, title: p[:title].presence
    }
    return attrs.merge(external_reference: item.external_reference.as_json) if item&.external_reference&.imported?

    ref = p[:external_reference]
    attrs[:external_reference] = ref if ref.present? && ref["url"].present?
    attrs
  end

  # True only when a content field was actually submitted AND differs. Disabled
  # (non-author) fields aren't submitted, so this is false — link-only path.
  def content_changed?(item, p)
    return false if p[:content].nil?

    p[:evidence_type] != item.evidence_type ||
      p[:custom_type_label].presence != item.custom_type_label.presence ||
      p[:title].presence != item.title.presence ||
      p[:content].to_s != item.content.to_s ||
      reference_changed?(item, p[:external_reference] || {})
  end

  def reference_changed?(item, ref)
    return false if item.external_reference&.imported?

    ref["system"].presence != item.external_reference&.system.presence ||
      ref["url"].presence != item.external_reference&.url.presence
  end

  def assignment_id_for(record)
    PersonFrameworkAssignment.find_by!(person_id: record.person_id, framework_id: record.framework_id).id
  end
end
