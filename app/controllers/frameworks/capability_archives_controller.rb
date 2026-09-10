# frozen_string_literal: true

# Archives a capability from the explorer's edit-mode row-actions kebab,
# submitted by the archive modal. The Operation decides — from the edit/suggest
# toggle (framework_edit_mode) plus the actor's authority — whether the archive
# applies directly or lands as a pending suggestion, so the kebab is offered to
# any suggest-rights holder. Migration mapping is captured as-we-go when
# present; otherwise it's validated at the publish-review screen.
#
# Restricted to suggest-rights holders via FrameworkPolicy#suggest_edit?.
class Frameworks::CapabilityArchivesController < ApplicationController
  include FrameworkEditMode
  include Frameworks::SuggestionAuthority
  include Frameworks::WriteResponse

  before_action :set_framework
  before_action :set_capability

  # POST /frameworks/:framework_id/capability_archives
  def create
    authorize @framework, :suggest_edit?

    result = Operations::Frameworks::ArchiveCapability.call(
      context: pundit_user,
      params: {
        framework_id: @framework.framework_id,
        capability_id: @capability.capability_id,
        reason: archive_params[:reason].presence,
        mapping_type: archive_params[:mapping_type].presence,
        to_stable_id: archive_params[:to_stable_id].presence,
        mode: framework_edit_mode.to_s
      }
    )

    message =
      if result[:archived]
        "Archived “#{@capability.name}”."
      else
        "Proposed archiving “#{@capability.name}” for review."
      end

    # A direct archive stages the removal into a draft: the row becomes struck
    # + "Pending archive" and the draft pill appears. A proposal only decorates
    # the row. Either way just the compact row changes.
    render_write_streams(
      [ toast_stream(message) ] +
      capability_replace_streams(@capability.capability_id) +
      draft_status_streams
    )
  rescue Operations::Base::ParameterError, RuntimeError => e
    render_write_error(e.message)
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
    render_write_error("that capability no longer exists — reload the page") unless @capability
  end
end
