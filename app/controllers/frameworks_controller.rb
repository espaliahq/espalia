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
      can_edit: fw_policy.edit?
    )
  end

  def render_matrix_frame(mode:)
    graph, matrix_data = load_explorer_matrix(mode: mode)

    render Views::Frameworks::MatrixFrameView.new(
      framework: graph,
      matrix_data: matrix_data,
      selected_role_ids: parse_role_ids,
      mode: mode
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
  # @param mode [Symbol] :view (public/contributor view of published state)
  #   or :edit (contributor view showing draft-only additions + pending archives)
  # @return [Array(Frameworks::ExplorerGraph::Framework, Hash)]
  def load_explorer_matrix(mode:)
    graph = Frameworks::ExplorerGraph.load(@framework.framework_id) ||
            Frameworks::ExplorerGraph.rebuild(@framework.framework_id)

    pending_suggestions, pending_illustration_creates = load_pending_suggestion_maps

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
  # @return [Array(Hash, Hash)] [entity counts map, illustration creates by parent]
  def load_pending_suggestion_maps
    base = FrameworkState::SuggestedEdit
      .where(framework_id: @framework.framework_id)
      .pending

    counts = base.group(:target_entity_type, :target_entity_id).count
    creates = base.creates
      .where(target_entity_type: "role_illustration")
      .to_a.group_by(&:parent_id)

    [ counts, creates ]
  end
end
