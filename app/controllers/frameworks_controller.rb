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
      current_person_id: current_person&.id&.to_s
    )
  end

  def render_matrix_frame(mode:)
    graph, matrix_data = load_explorer_matrix(mode: mode)

    render Views::Frameworks::MatrixFrameView.new(
      framework: graph,
      matrix_data: matrix_data,
      selected_role_ids: parse_role_ids,
      mode: mode,
      current_person_id: current_person&.id&.to_s
    ), layout: false
  end

  def set_framework
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:id))
  rescue ActiveRecord::RecordNotFound
    redirect_to frameworks_path
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
      pending_illustration_creates: pending_illustration_creates
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

  # Iterates pending suggestions once, aggregating counts and capturing
  # the latest edit per entity for the four inline-diff text fields.
  TEXT_EDIT_FIELDS = {
    "capability_category" => "name",
    "capability" => "name",
    "behavioural_expectation" => "description",
    "role_illustration" => "description"
  }.freeze
  private_constant :TEXT_EDIT_FIELDS

  def build_suggestions_map(scope)
    suggestions = {}
    # find_each ignores any scoped `order`, so we pick the latest edit per
    # entity by comparing created_at inside the loop rather than relying on
    # iteration order.
    scope.find_each do |edit|
      key = [ edit.target_entity_type, edit.target_entity_id ]
      entry = suggestions[key] ||= { count: 0, latest_edit: nil }
      entry[:count] += 1

      next unless edit.kind == "edit" && TEXT_EDIT_FIELDS[edit.target_entity_type] == edit.field

      current = entry[:latest_edit]
      if current
        next if current[:created_at] > edit.created_at
        next if current[:created_at] == edit.created_at && current[:id] >= edit.id
      end

      entry[:latest_edit] = {
        id: edit.id,
        suggested_value: edit.suggested_value,
        suggestion_id: edit.suggestion_id,
        created_at: edit.created_at
      }
    end
    suggestions
  end
end
