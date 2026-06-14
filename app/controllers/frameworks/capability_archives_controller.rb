# frozen_string_literal: true

# Archives a capability from the explorer's edit-mode row kebab, capturing
# its migration mapping as-we-go (the owner/editor validates/overrides it on
# the publish-review screen). A capability added in the current draft has
# nothing to migrate, so no mapping is requested.
#
# Restricted to edit-rights holders via FrameworkPolicy#archive_capability?.
class Frameworks::CapabilityArchivesController < ApplicationController
  before_action :set_framework
  before_action :set_capability

  # GET /frameworks/:framework_id/capabilities/:capability_id/archive/new
  def new
    authorize @framework, :archive_capability?

    render Views::Frameworks::Capabilities::ArchiveView.new(
      framework: @framework,
      capability: @capability,
      needs_mapping: needs_mapping?,
      survivors: survivor_candidates
    )
  end

  # POST /frameworks/:framework_id/capabilities/:capability_id/archive
  def create
    authorize @framework, :archive_capability?
    attrs = params.expect(archive: [ :reason, :mapping_type, :to_stable_id ])

    Operations::Frameworks::ArchiveCapability.call(
      context: pundit_user,
      params: {
        framework_id: @framework.framework_id,
        capability_id: @capability.capability_id,
        reason: attrs[:reason].presence,
        mapping_type: attrs[:mapping_type].presence,
        to_stable_id: attrs[:to_stable_id].presence
      }
    )

    redirect_to edit_framework_path(@framework.framework_id),
                notice: "Archived “#{@capability.name}”."
  rescue Operations::Base::ParameterError, RuntimeError => e
    redirect_to edit_framework_path(@framework.framework_id), alert: e.message
  end

  private

  def set_framework
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:framework_id))
  rescue ActiveRecord::RecordNotFound
    redirect_to frameworks_path
  end

  def set_capability
    @capability = FrameworkState::Capability.joins(:category).find_by!(
      capability_id: params.expect(:capability_id),
      framework_capability_categories: { framework_id: @framework.framework_id }
    )
  rescue ActiveRecord::RecordNotFound
    redirect_to edit_framework_path(@framework.framework_id)
  end

  # A capability that already existed before the current draft must declare a
  # migration mapping; one added during the draft has nothing to migrate.
  # The graph's `added_in_draft` flag is the source of truth.
  def needs_mapping?
    node = graph_capability_node
    node.nil? || !node.added_in_draft
  end

  def graph_capability_node
    graph = Frameworks::ExplorerGraph.load(@framework.framework_id) ||
            Frameworks::ExplorerGraph.rebuild(@framework.framework_id)
    graph.capability_categories
      .flat_map(&:capabilities)
      .find { |c| c.capability_id == @capability.capability_id }
  end

  # Active capabilities in this framework, excluding the one being archived —
  # candidate survivors for same/evolved/split mappings.
  def survivor_candidates
    FrameworkState::Capability.joins(:category)
      .where(framework_capability_categories: { framework_id: @framework.framework_id })
      .active
      .where.not(capability_id: @capability.capability_id)
      .order(:name)
  end
end
