# frozen_string_literal: true

# Builds the explorer's matrix data for a request, and the per-viewer flags every
# matrix render threads down to the cells.
#
# Extracted from {FrameworksController} because the explorer's **write**
# endpoints need it too: since every edit-mode write answers a surgical Turbo
# Stream instead of redirecting, each of them has to re-render the rows it
# touched against exactly the scope (roles / track / search) the page was
# rendered under — the same builder, the same flags, or the streamed row drifts
# from the row beside it.
#
# Requires `@framework` (a {FrameworkState::Framework}) to be set, and the
# including controller to `include Frameworks::SuggestionAuthority`.
module Frameworks::ExplorerMatrix
  extend ActiveSupport::Concern

  private

  # The per-viewer flags every matrix render threads down to the cells —
  # one definition so the explorer shell, the matrix frame and the on-demand
  # expanded row can't gate an affordance differently (Hard-Won Lessons 13/16).
  #
  # @return [Hash] current_person_id / can_edit_structure / approval_authority
  def viewer_matrix_flags(mode)
    {
      current_person_id: current_person&.id&.to_s,
      can_edit_structure: mode == :edit && policy(@framework).edit_structure?,
      approval_authority: suggestion_approval_authority(mode)
    }
  end

  # Per-viewer suggestion-approval authority, so the matrix row kebab can offer
  # inline approve/reject for a capability's pending edits (same value object the
  # activity feed uses). Only meaningful in edit mode — the kebab is edit-only.
  def suggestion_approval_authority(mode)
    return Frameworks::SuggestionApprovalAuthority.none unless mode == :edit

    framework_suggestion_approval_authority
  end

  # Builds the matrix data consumed by the explorer. Sources structural
  # data from the persisted {Frameworks::ExplorerGraph} snapshot; pending
  # suggestions still come from the AR suggested_edits table.
  #
  # View mode surfaces no pending-suggestion hints in the grid (no wavy
  # underlines, no "N pending" pill, no ghost-entry illustrations) — that
  # visual chatter belongs in edit mode only, where contributors are
  # actively reviewing in-flight changes. Edit mode gets the full maps.
  #
  # @param mode [Symbol] :view (public/contributor view of published state)
  #   or :edit (contributor view showing draft-only additions + pending archives)
  # @return [Array(Frameworks::ExplorerGraph::Framework, Hash)]
  def load_explorer_matrix(mode:)
    graph = Frameworks::ExplorerGraph.load(@framework.framework_id) ||
            Frameworks::ExplorerGraph.rebuild(@framework.framework_id)

    pending_suggestions, pending_illustration_creates, pending_expectation_creates =
      mode == :edit ? load_pending_suggestion_maps : [ {}, {}, {} ]

    matrix_data = Frameworks::MatrixDataBuilder.new(
      framework: graph,
      role_families: graph.role_families,
      categories: graph.capability_categories,
      selected_role_ids: parse_role_ids,
      track_filter: resolved_track_filter,
      mode: mode,
      pending_suggestions: pending_suggestions,
      pending_illustration_creates: pending_illustration_creates,
      pending_expectation_creates: pending_expectation_creates,
      search_query: resolved_search_query
    ).build

    [ graph, matrix_data ]
  end

  # @return [Array<String>] role UUIDs from params
  def parse_role_ids
    Array.wrap(params[:roles]).select(&:present?)
  end

  def resolved_track_filter
    params[:track].presence || "both"
  end

  # Free-text matrix filter (see {Frameworks::MatrixDataBuilder}). Trimmed;
  # blank collapses to nil so the builder treats it as "not searching".
  #
  # @return [String, nil]
  def resolved_search_query
    params[:q].to_s.strip.presence
  end

  # Loads pending suggestion maps for the matrix visual affordance.
  #
  # Returned `suggestions` map is keyed by `[entity_type, entity_id]` and
  # carries both a `count` (used for badges / pills) and `latest_edit`
  # (the most recent pending `kind: "edit"` on the in-scope text field,
  # or nil) — {Views::Frameworks::Explorer::Concerns::SuggestionDecoration#render_inline_diff}
  # uses `latest_edit[:suggested_value]` to produce the inline diff.
  #
  # @return [Array(Hash, Hash)] [suggestions map, illustration creates by parent]
  def load_pending_suggestion_maps
    base = FrameworkState::SuggestedEdit
      .where(framework_id: @framework.framework_id)
      .pending

    suggestions = build_suggestions_map(base)
    creates = base.creates
      .where(target_entity_type: "role_illustration")
      .to_a.group_by(&:parent_id)
    # Pending expectation creates, keyed by [capability_id, level_ordinal] so the
    # matrix cell at that position can render a ghost of the proposed expectation.
    expectation_creates = base.creates
      .where(target_entity_type: "behavioural_expectation")
      .to_a.group_by { |s| [ s.parent_id, s.proposed_attributes["level_ordinal"].to_i ] }

    [ suggestions, creates, expectation_creates ]
  end

  # Iterates pending suggestions once, aggregating the per-entity count and the
  # latest edit *per field* — so each inline-diff frame (capability name AND
  # description, category name, expectation/illustration description) can pick
  # the latest edit on its own field.
  def build_suggestions_map(scope)
    suggestions = {}
    # find_each ignores any scoped `order`, so we pick the latest edit per
    # entity+field by comparing created_at inside the loop rather than relying
    # on iteration order.
    scope.find_each do |edit|
      key = [ edit.target_entity_type, edit.target_entity_id ]
      entry = suggestions[key] ||= { count: 0, clarification_count: 0, latest_by_field: {} }

      # Clarifications are discussions, not pending changes — they feed the
      # comment glyph, never the wiggle/diff/"N pending" pending-change
      # vocabulary, so they stay out of :count and :latest_by_field. The glyph
      # is clickable, so keep the latest one's id for it to open.
      if edit.kind == "clarification"
        entry[:clarification_count] += 1
        entry[:latest_clarification] = latest_of(entry[:latest_clarification], edit)
        next
      end

      entry[:count] += 1

      next unless edit.kind == "edit" && edit.field.present?

      current = entry[:latest_by_field][edit.field]
      if current
        next if current[:created_at] > edit.created_at
        next if current[:created_at] == edit.created_at && current[:id] >= edit.id
      end

      entry[:latest_by_field][edit.field] = {
        id: edit.id,
        suggested_value: edit.suggested_value,
        suggestion_id: edit.suggestion_id,
        created_at: edit.created_at
      }
    end
    suggestions
  end

  # The later of two suggestions. `find_each` ignores any scoped order, so
  # recency is decided here — id breaks a created_at tie.
  #
  # @param current [Hash, nil] the incumbent `{ id:, suggestion_id:, created_at: }`
  # @param edit [FrameworkState::SuggestedEdit]
  # @return [Hash]
  def latest_of(current, edit)
    if current
      return current if current[:created_at] > edit.created_at
      return current if current[:created_at] == edit.created_at && current[:id] >= edit.id
    end

    { id: edit.id, suggestion_id: edit.suggestion_id, created_at: edit.created_at }
  end
end
