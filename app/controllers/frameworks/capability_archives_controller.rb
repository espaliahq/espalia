# frozen_string_literal: true

# Archives a capability from the explorer's edit-mode row-actions kebab,
# submitted by the archive modal. Captures the migration mapping as-we-go for
# a pre-draft capability (the owner/editor validates/overrides it on the
# publish-review screen). A capability added in the current draft has nothing
# to migrate, so the modal omits the mapping fields.
#
# Restricted to edit-rights holders via FrameworkPolicy#archive_capability?.
class Frameworks::CapabilityArchivesController < ApplicationController
  before_action :set_framework
  before_action :set_capability

  # POST /frameworks/:framework_id/capability_archives
  def create
    authorize @framework, :archive_capability?

    Operations::Frameworks::ArchiveCapability.call(
      context: pundit_user,
      params: {
        framework_id: @framework.framework_id,
        capability_id: @capability.capability_id,
        reason: archive_params[:reason].presence,
        mapping_type: archive_params[:mapping_type].presence,
        to_stable_id: archive_params[:to_stable_id].presence
      }
    )

    redirect_to edit_framework_path(@framework.framework_id),
                notice: "Archived “#{@capability.name}”."
  rescue Operations::Base::ParameterError, RuntimeError => e
    redirect_to edit_framework_path(@framework.framework_id), alert: e.message
  end

  private

  def archive_params
    @archive_params ||= params.expect(archive: [ :capability_id, :reason, :mapping_type, :to_stable_id ])
  end

  def set_framework
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:framework_id))
  rescue ActiveRecord::RecordNotFound
    redirect_to frameworks_path
  end

  # Scope the capability lookup through its category to the authorized
  # framework — capability_id alone is not safe across a tenant's frameworks.
  # Resolve from the explorer graph (NOT the published read model) so a
  # capability added in the current draft can be archived too. The graph is
  # per-framework, so finding the id in it scopes to the authorized framework.
  def set_capability
    graph = Frameworks::ExplorerGraph.load(@framework.framework_id) ||
            Frameworks::ExplorerGraph.rebuild(@framework.framework_id)
    @capability = graph.capability_categories.flat_map(&:capabilities)
      .find { |c| c.capability_id == archive_params[:capability_id] }
    redirect_to edit_framework_path(@framework.framework_id) unless @capability
  end
end
