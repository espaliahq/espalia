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

  # Conditional-GET key for a matrix (or expanded-row) render, so a filter
  # toggled back to a state the browser already holds costs a 304 instead of a
  # re-download and re-parse of the whole grid.
  #
  # Every input the rendered HTML depends on is in here: the graph snapshot
  # (structure), the pending-suggestion table (edit-mode decorations), the
  # three filter axes, the mode, and the viewer's own permissions — plus the
  # running release, without which a deploy that changed the markup would keep
  # being answered from the previous release's HTML.
  #
  # Returns nil — no ETag, always a full render — when there is nothing
  # dependable to key on:
  #
  # - no persisted graph row (test factories and AR-only frameworks build the
  #   graph on the fly from `FrameworkState::*`, whose freshness this key does
  #   not capture);
  # - in development, where code reloading changes the markup without moving
  #   any of these inputs.
  #
  # @param mode [Symbol] :view or :edit
  # @param extra [Object] anything narrowing the render further (the expanded
  #   row's capability id)
  # @return [Array, nil]
  def explorer_matrix_etag(mode:, extra: nil)
    return nil if Rails.env.development?

    snapshot = FrameworkExplorerGraph
      .where(framework_id: @framework.framework_id)
      .pick(:updated_at, :format_version)
    return nil unless snapshot

    flags = viewer_matrix_flags(mode)
    [
      "explorer-matrix",
      Rails.application.config.x.release_id,
      @framework.framework_id,
      [ timestamp_token(snapshot.first), snapshot.last ],
      suggestion_freshness(mode),
      mode,
      parse_role_ids.sort,
      resolved_track_filter,
      resolved_search_query,
      flags[:current_person_id],
      flags[:can_edit_structure],
      flags[:approval_authority].cache_key,
      extra
    ]
  end

  # Freshness of the pending-suggestion decorations (wiggles, diffs, ghosts,
  # clarification glyphs). Nil in view mode, which renders none of them.
  #
  # MAX(updated_at) alone would miss a row leaving the table, so the count
  # rides along — the projection resolves rather than deletes today, but an
  # ETag that assumes it will keep doing so is a stale grid waiting to happen.
  #
  # @return [Array, nil]
  def suggestion_freshness(mode)
    return nil unless mode == :edit

    latest, count = FrameworkState::SuggestedEdit
      .where(framework_id: @framework.framework_id)
      .pick(Arel.sql("MAX(updated_at)"), Arel.sql("COUNT(*)"))

    [ timestamp_token(latest), count ]
  end

  # Sub-second-precision token for a timestamp in a cache key.
  #
  # `ActiveSupport::Cache.expand_cache_key` stringifies a Time through
  # `to_param`, which drops to WHOLE SECONDS — so two edits inside the same
  # second produced the same key and the second one was answered with a stale
  # 304. Nanoseconds, the way ActiveRecord's own `cache_version` does it.
  #
  # @return [String, nil]
  def timestamp_token(time)
    time&.utc&.to_fs(:nsec)
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
    graph = load_explorer_graph
    [ graph, explorer_builder(graph, mode: mode, include_illustrations: false).build ]
  end

  # The compact matrix and the on-demand expanded row differ in two ways only:
  # the row needs one capability, and it is the only surface that renders
  # illustrations. Both are the same builder, so the row can never drift from
  # the compact row it sits under (Hard-Won Lesson 25).
  #
  # @param mode [Symbol] :view or :edit
  # @param capability_id [String]
  # @return [Array(Frameworks::ExplorerGraph::Framework, Hash)] the graph and
  #   `{ selected_roles:, merged_levels:, capability: }` — `capability` nil when
  #   out of scope
  def load_expanded_row_data(mode:, capability_id:)
    graph = load_explorer_graph
    builder = explorer_builder(
      graph, mode: mode, include_illustrations: true,
      suggestion_scope: capability_suggestion_scope(graph, capability_id)
    )

    [ graph, builder.build_capability(capability_id) ]
  end

  def load_explorer_graph
    Frameworks::ExplorerGraph.load(@framework.framework_id) ||
      Frameworks::ExplorerGraph.rebuild(@framework.framework_id)
  end

  def explorer_builder(graph, mode:, include_illustrations:, suggestion_scope: nil)
    pending_suggestions, pending_illustration_creates, pending_expectation_creates =
      mode == :edit ? load_pending_suggestion_maps(scope: suggestion_scope) : [ {}, {}, {} ]

    Frameworks::MatrixDataBuilder.new(
      framework: graph,
      role_families: graph.role_families,
      categories: graph.capability_categories,
      selected_role_ids: parse_role_ids,
      track_filter: resolved_track_filter,
      mode: mode,
      pending_suggestions: pending_suggestions,
      pending_illustration_creates: pending_illustration_creates,
      pending_expectation_creates: pending_expectation_creates,
      search_query: resolved_search_query,
      include_illustrations: include_illustrations
    )
  end

  # Every entity id one capability's expanded row can decorate — itself, its
  # expectations, and their illustrations — so the pending-suggestion load for
  # an expand reads that capability's rows rather than the whole framework's.
  #
  # @return [Hash, nil] `{ entity_ids:, parent_ids: }`, or nil when the graph has
  #   no such capability (the builder then answers "not in scope" and we 404)
  def capability_suggestion_scope(graph, capability_id)
    capability = graph.capability_categories
      .flat_map(&:capabilities)
      .find { |c| c.capability_id == capability_id }
    return nil unless capability

    expectation_ids = capability.expectations.map(&:expectation_id)
    illustration_ids = capability.expectations.flat_map { |e| e.illustrations.map(&:illustration_id) }

    # `parent_ids` is the creates axis: a pending illustration hangs off its
    # expectation, a pending expectation off its capability.
    { entity_ids: [ capability_id ] + expectation_ids + illustration_ids,
      parent_ids: [ capability_id ] + expectation_ids }
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
  # @param scope [Hash, nil] `{ entity_ids:, parent_ids: }` narrowing the read to
  #   one capability's rows (the expanded row). nil reads the whole framework's,
  #   which is what the matrix needs.
  def load_pending_suggestion_maps(scope: nil)
    base = FrameworkState::SuggestedEdit
      .where(framework_id: @framework.framework_id)
      .pending

    edits = scope ? base.where(target_entity_id: scope[:entity_ids]) : base
    creates = scope ? base.creates.where(parent_id: scope[:parent_ids]) : base.creates

    suggestions = build_suggestions_map(edits)
    illustration_creates = creates
      .where(target_entity_type: "role_illustration")
      .to_a.group_by(&:parent_id)
    # Pending expectation creates, keyed by [capability_id, level_ordinal] so the
    # matrix cell at that position can render a ghost of the proposed expectation.
    expectation_creates = creates
      .where(target_entity_type: "behavioural_expectation")
      .to_a.group_by { |s| [ s.parent_id, s.proposed_attributes["level_ordinal"].to_i ] }

    [ suggestions, illustration_creates, expectation_creates ]
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
