# frozen_string_literal: true

class FrameworksController < ApplicationController
  before_action :set_framework, only: [ :show, :matrix ]

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
    tenants = ActsAsTenant.without_tenant { current_user.tenants.to_a }
    role_families = load_role_families
    categories = load_categories
    selected_role_ids = parse_role_ids
    track_filter = params[:track].presence || "both"

    pending_suggestions, pending_illustration_creates = load_pending_suggestion_maps

    matrix_data = Frameworks::MatrixDataBuilder.new(
      framework: @framework, role_families: role_families,
      categories: categories,
      selected_role_ids: selected_role_ids, track_filter: track_filter,
      pending_suggestions: pending_suggestions,
      pending_illustration_creates: pending_illustration_creates
    ).build

    render Views::Frameworks::ShowView.new(
      framework: @framework,
      role_families: role_families,
      selected_role_ids: selected_role_ids,
      track_filter: track_filter,
      matrix_data: matrix_data,
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: tenants,
      is_admin: policy(@framework).admin?,
      pending_suggestion_count: @framework.suggested_edits.where(status: "pending").count
    )
  end

  # GET /frameworks/:id/matrix
  def matrix
    authorize @framework, :matrix?
    role_families = load_role_families
    categories = load_categories
    selected_role_ids = parse_role_ids
    track_filter = params[:track].presence || "both"

    pending_suggestions, pending_illustration_creates = load_pending_suggestion_maps

    matrix_data = Frameworks::MatrixDataBuilder.new(
      framework: @framework, role_families: role_families,
      categories: categories,
      selected_role_ids: selected_role_ids, track_filter: track_filter,
      pending_suggestions: pending_suggestions,
      pending_illustration_creates: pending_illustration_creates
    ).build

    render Views::Frameworks::MatrixFrameView.new(
      framework: @framework,
      matrix_data: matrix_data,
      selected_role_ids: selected_role_ids
    ), layout: false
  end

  private

  def set_framework
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:id))
  rescue ActiveRecord::RecordNotFound
    redirect_to frameworks_path
  end

  # @return [Array<String>] role UUIDs from params
  def parse_role_ids
    Array.wrap(params[:roles]).select(&:present?)
  end

  # @return [ActiveRecord::Relation<FrameworkState::RoleFamily>]
  def load_role_families
    @framework.role_families.includes(roles: :levels).order(:name)
  end

  # @return [ActiveRecord::Relation<FrameworkState::CapabilityCategory>]
  def load_categories
    @framework.capability_categories
      .includes(capabilities: [ :bindings, { expectations: :illustrations } ])
      .order(:ordinal)
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
