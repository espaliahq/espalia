# frozen_string_literal: true

class FrameworksController < ApplicationController
  include Frameworks::SuggestionAuthority
  include Frameworks::ExplorerMatrix
  include FrameworkEditMode

  before_action :set_framework, only: [ :show, :matrix, :edit, :edit_matrix, :expanded_row, :edit_expanded_row ]

  # GET /frameworks
  def index
    authorize FrameworkState::Framework, :index?
    @page_title = "Frameworks"
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
    @page_title = @framework.name
    render_explorer(mode: :view)
  end

  # GET /frameworks/:id/matrix
  def matrix
    authorize @framework, :matrix?
    return if matrix_fresh?(mode: :view)

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
    @page_title = "#{@framework.name} · Edit"
    render_explorer(mode: :edit)
  end

  # GET /frameworks/:id/edit/matrix
  def edit_matrix
    authorize @framework, :edit_matrix?
    return if matrix_fresh?(mode: :edit)

    render_matrix_frame(mode: :edit)
  end

  # GET /frameworks/:id/expanded_rows/:capability_id
  #
  # One capability's expanded row (per-role illustrations), fetched by the
  # matrix controller the first time the row is expanded. The matrix itself
  # ships only a placeholder per row — see {Views::Frameworks::Explorer::ExpandedRow}.
  def expanded_row
    authorize @framework, :matrix?
    return if matrix_fresh?(mode: :view, extra: params.expect(:capability_id))

    render_expanded_row(mode: :view)
  end

  # GET /frameworks/:id/edit/expanded_rows/:capability_id
  def edit_expanded_row
    authorize @framework, :edit_matrix?
    return if matrix_fresh?(mode: :edit, extra: params.expect(:capability_id))

    render_expanded_row(mode: :edit)
  end

  private

  # Sets the conditional-GET ETag for a matrix render and reports whether the
  # request was answered with a 304. Turbo frame fetches and the expanded row's
  # request.js GET both send `If-None-Match`, so a filter toggled back to a
  # state the browser already holds costs neither a download nor a re-parse.
  #
  # Deliberately BEFORE the graph load and the builder: the key is four cheap
  # reads, the render it guards is the expensive part.
  #
  # @return [Boolean] true when a 304 has already been sent
  def matrix_fresh?(mode:, extra: nil)
    etag = explorer_matrix_etag(mode: mode, extra: extra)
    return false unless etag

    fresh_when(etag: etag)
    performed?
  end

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
      # Proposals only — an open clarification is a discussion, not a pending
      # change, and must not inflate the header's pending-change badge.
      pending_suggestion_count: @framework.suggested_edits.pending.proposals.count,
      mode: mode,
      publishing: mode == :edit && fw_policy.publish? && FrameworkPublication.in_flight_for?(@framework.framework_id),
      can_edit: fw_policy.edit?,
      can_publish: fw_policy.publish?,
      # The header's rename pencil — admin / owner only; the frame itself
      # renders it in edit mode only, like the org-structure rename frames.
      can_rename: fw_policy.rename?,
      archive_survivors: can_edit_structure ? archive_survivors(graph) : [],
      roles: can_edit_structure ? framework_roles(graph) : [],
      search_query: resolved_search_query,
      # The editor's Save-vs-Propose label needs the Editing/Suggesting cookie
      # as well as the viewer's authority (#379).
      edit_mode: framework_edit_mode,
      **viewer_matrix_flags(mode)
    )
  end

  # Renders the loaded expanded `<tr>` for one capability under the current
  # role/track scope. Runs the same builder as the matrix (in-memory, a few ms)
  # and picks the capability out, so the row can't drift from what the compact
  # row was rendered against. 404 when the capability isn't in scope (archived,
  # filtered out by the role selection, or not this framework's).
  def render_expanded_row(mode:)
    _graph, row_data = load_expanded_row_data(mode: mode, capability_id: params.expect(:capability_id))
    return head :not_found unless row_data[:capability]

    render Views::Frameworks::Explorer::ExpandedRow.new(
      capability_data: row_data[:capability],
      merged_levels: row_data[:merged_levels],
      framework_id: @framework.framework_id,
      loaded: true,
      mode: mode,
      roles_by_id: row_data[:selected_roles].index_by(&:role_id),
      **viewer_matrix_flags(mode)
    ), layout: false
  end

  def render_matrix_frame(mode:)
    graph, matrix_data = load_explorer_matrix(mode: mode)

    render Views::Frameworks::MatrixFrameView.new(
      framework: graph,
      matrix_data: matrix_data,
      selected_role_ids: parse_role_ids,
      mode: mode,
      **viewer_matrix_flags(mode)
    ), layout: false
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
end
