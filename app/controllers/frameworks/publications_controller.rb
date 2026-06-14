# frozen_string_literal: true

# Publishes the current draft of a framework as a new version.
#
# The web is the in-app confirmation surface for the otherwise :in_app
# {Operations::Frameworks::PublishVersion}, so it dispatches the operation
# directly (behind a Turbo confirm dialog in the explorer header). Restricted
# to owners / editors and tenant admins via FrameworkPolicy#publish?.
class Frameworks::PublicationsController < ApplicationController
  before_action :set_framework

  # GET /frameworks/:framework_id/publication/new
  #
  # Publish-review screen: a draft summary plus every capability being retired
  # with its (editable) migration mapping, so the owner/editor validates the
  # as-we-go choices before confirming.
  def new
    authorize @framework, :publish?

    render Views::Frameworks::PublicationReviewView.new(
      framework: @framework,
      retiring: retiring_capabilities,
      survivors: survivor_candidates,
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: ActsAsTenant.without_tenant { current_user.tenants.to_a }
    )
  end

  # POST /frameworks/:framework_id/publication
  def create
    authorize @framework, :publish?

    result = Operations::Frameworks::PublishVersion.call(
      context: pundit_user,
      params: { framework_id: @framework.framework_id }
    )

    redirect_to edit_framework_path(@framework.framework_id),
                notice: "Published v#{result[:published_version]}."
  rescue RuntimeError => e
    redirect_to edit_framework_path(@framework.framework_id),
                alert: e.message
  end

  private

  def set_framework
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:framework_id))
  rescue ActiveRecord::RecordNotFound
    redirect_to frameworks_path
  end

  # Capabilities staged for archive in the current draft that existed before
  # it (added-in-draft archives need no migration). Each is paired with its
  # current mapping, if one was recorded as-we-go. Sourced from the edit-mode
  # graph (the archive is deferred from the published read model during draft).
  def retiring_capabilities
    graph = Frameworks::ExplorerGraph.load(@framework.framework_id) ||
            Frameworks::ExplorerGraph.rebuild(@framework.framework_id)
    mappings = mappings_by_from_stable_id

    graph.capability_categories.flat_map(&:capabilities)
      .select { |c| c.pending_archive && !c.added_in_draft }
      .map { |c| { capability: c, mapping: mappings[c.stable_id] } }
  end

  def mappings_by_from_stable_id
    FrameworkState::MigrationMapping
      .where(framework_id: @framework.framework_id, published_version: @framework.draft_version)
      .index_by(&:from_stable_id)
  end

  # Capabilities that will exist post-publish (not being retired) — survivor
  # candidates for evolved/split mappings.
  def survivor_candidates
    graph = Frameworks::ExplorerGraph.load(@framework.framework_id) ||
            Frameworks::ExplorerGraph.rebuild(@framework.framework_id)
    graph.capability_categories.flat_map(&:capabilities)
      .reject(&:pending_archive)
      .map { |c| { name: c.name, stable_id: c.stable_id } }
      .sort_by { |c| c[:name] }
  end
end
