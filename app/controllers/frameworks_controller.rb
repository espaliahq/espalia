# frozen_string_literal: true

class FrameworksController < ApplicationController
  before_action :set_framework, only: [ :show, :matrix, :edit, :edit_matrix ]

  # GET /frameworks
  def index
    authorize FrameworkState::Framework, :index?
    @frameworks = FrameworkState::Framework.all
    tenants = ActsAsTenant.without_tenant { current_user.tenants.to_a }

    render Views::Frameworks::IndexView.new(
      frameworks: @frameworks,
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: tenants
    )
  end

  # GET /frameworks/:id
  def show
    authorize @framework
    render_explorer(mode: :view)
  end

  # GET /frameworks/:id/matrix
  def matrix
    authorize @framework, :matrix?
    render_matrix_frame(mode: :view)
  end

  # GET /frameworks/:id/edit
  #
  # Edit-mode counterpart of #show. Restricted to collaborators with suggest
  # rights (see FrameworkPolicy#edit?). Renders the same explorer shell but
  # sources the matrix from the graph in :edit mode, so draft-only
  # entities and pending archives become visible.
  def edit
    authorize @framework, :edit?
    render_explorer(mode: :edit)
  end

  # GET /frameworks/:id/edit/matrix
  def edit_matrix
    authorize @framework, :edit_matrix?
    render_matrix_frame(mode: :edit)
  end

  private

  # Renders the full Framework Explorer shell for the given mode. Keeps
  # show/#edit symmetric — only mode and the `can_edit`/`is_admin` flags
  # differ between them.
  def render_explorer(mode:)
    graph, matrix_data = load_explorer_matrix(mode: mode)
    tenants = ActsAsTenant.without_tenant { current_user.tenants.to_a }
    fw_policy = policy(@framework)
    can_edit_structure = mode == :edit && fw_policy.edit_structure?

    render Views::Frameworks::ShowView.new(
      framework: graph,
      role_families: graph.role_families,
      selected_role_ids: parse_role_ids,
      track_filter: resolved_track_filter,
      matrix_data: matrix_data,
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: tenants,
      is_admin: fw_policy.admin?,
      pending_suggestion_count: @framework.suggested_edits.where(status: "pending").count,
      mode: mode,
      can_edit: fw_policy.edit?,
      can_publish: fw_policy.publish?,
      can_edit_structure: can_edit_structure,
      approval_authority: suggestion_approval_authority(mode),
      archive_survivors: can_edit_structure ? archive_survivors(graph) : [],
      roles: can_edit_structure ? framework_roles(graph) : [],
      current_person_id: current_person&.id&.to_s,
      search_query: resolved_search_query
    )
  end

  def render_matrix_frame(mode:)
    graph, matrix_data = load_explorer_matrix(mode: mode)

    render Views::Frameworks::MatrixFrameView.new(
      framework: graph,
      matrix_data: matrix_data,
      selected_role_ids: parse_role_ids,
      mode: mode,
      current_person_id: current_person&.id&.to_s,
      can_edit_structure: mode == :edit && policy(@framework).edit_structure?,
      approval_authority: suggestion_approval_authority(mode)
    ), layout: false
  end

  # Per-viewer suggestion-approval authority, so the matrix row kebab can offer
  # inline approve/reject for a capability's pending edits (same value object the
  # activity feed uses). Only meaningful in edit mode — the kebab is edit-only.
  def suggestion_approval_authority(mode)
    return Frameworks::SuggestionApprovalAuthority.none unless mode == :edit

    Frameworks::SuggestionApprovalAuthority.for(
      framework_id: @framework.framework_id,
      person: current_person,
      tenant_admin: current_user&.global_admin? || current_tenant_user&.admin? || false
    )
  end

  def set_framework
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:id))
  rescue ActiveRecord::RecordNotFound
    redirect_to frameworks_path
  end

  # Role binding candidates for the add-capability modal, as { id:, label: }.
  def framework_roles(graph)
    graph.role_families.flat_map(&:roles)
      .map { |r| { id: r.role_id, label: r.name } }
      .sort_by { |r| r[:label] }
  end

  # Survivor candidates for the archive modal's Evolve mapping — every
  # capability not itself being retired, as { name:, stable_id: }.
  def archive_survivors(graph)
    graph.capability_categories.flat_map(&:capabilities)
      .reject(&:pending_archive)
      .map { |c| { name: c.name, stable_id: c.stable_id } }
      .sort_by { |c| c[:name] }
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

    pending_suggestions, pending_illustration_creates =
      mode == :edit ? load_pending_suggestion_maps : [ {}, {} ]

    matrix_data = Frameworks::MatrixDataBuilder.new(
      framework: graph,
      role_families: graph.role_families,
      categories: graph.capability_categories,
      selected_role_ids: parse_role_ids,
      track_filter: resolved_track_filter,
      mode: mode,
      pending_suggestions: pending_suggestions,
      pending_illustration_creates: pending_illustration_creates,
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

    [ suggestions, creates ]
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
      entry = suggestions[key] ||= { count: 0, latest_by_field: {} }
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
end
