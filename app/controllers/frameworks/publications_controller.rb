# frozen_string_literal: true

# Requests publication of a framework's current draft.
#
# Publishing migrates every assigned person's ratings, evidence and comments
# onto the new version, which does not fit in a web request, so `create`
# records a {FrameworkPublication} and enqueues {Frameworks::PublishVersionJob};
# the job runs the otherwise :in_app {Operations::Frameworks::PublishVersion}
# as the requester. The web is the confirmation surface: `new` is the review
# page where the migration mappings are checked before anything is enqueued.
# Restricted to owners / editors and tenant admins via FrameworkPolicy#publish?.
class Frameworks::PublicationsController < ApplicationController
  before_action :set_framework
  before_action :require_draft

  # GET /frameworks/:framework_id/publication/new
  #
  # Publish-review screen: a draft summary plus every capability being retired
  # with its (editable) migration mapping, so the owner/editor validates the
  # as-we-go choices before confirming. Also reports the latest publish request
  # for this draft — in flight, or why the last one failed.
  def new
    authorize @framework, :publish?

    render Views::Frameworks::PublicationReviewView.new(
      framework: @framework,
      retiring: retiring_capabilities,
      survivors: survivor_candidates,
      publication: latest_publication,
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: ActsAsTenant.without_tenant { current_user.tenants.to_a }
    )
  end

  # POST /frameworks/:framework_id/publication
  #
  # The publish gate the aggregate enforces (ADR-17) is checked here first so a
  # missing mapping is an immediate answer, not a failure notification minutes
  # later. The partial unique index on framework_publications refuses a second
  # in-flight request even when two submits race across web processes.
  def create
    authorize @framework, :publish?

    unmapped = retiring_capabilities.select { |entry| entry[:mapping].nil? }.map { |entry| entry[:capability].name }
    if unmapped.any?
      return redirect_to new_framework_publication_path(@framework.framework_id),
                         alert: "Add a migration mapping before publishing: #{unmapped.to_sentence}."
    end

    publication = FrameworkPublication.create!(
      tenant: ActsAsTenant.current_tenant,
      framework_id: @framework.framework_id,
      draft_version: @framework.draft_version,
      requested_by: current_tenant_user
    )
    Frameworks::PublishVersionJob.perform_later(publication)

    redirect_to edit_framework_path(@framework.framework_id),
                notice: "Publishing v#{@framework.draft_version} in the background — " \
                        "you'll be notified when it's live."
  rescue ActiveRecord::RecordNotUnique
    redirect_to edit_framework_path(@framework.framework_id),
                alert: "v#{@framework.draft_version} is already being published."
  end

  private

  def set_framework
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:framework_id))
  rescue ActiveRecord::RecordNotFound
    redirect_to frameworks_path
  end

  # Nothing to review or publish without a draft — say so immediately rather
  # than rendering "Publish v" or queueing a job that can only fail.
  def require_draft
    return if performed? || @framework.draft?

    redirect_to edit_framework_path(@framework.framework_id), alert: "No draft in progress."
  end

  def latest_publication
    FrameworkPublication.latest_for(@framework.framework_id, @framework.draft_version)
  end

  # Capabilities staged for archive in the current draft that existed before
  # it (added-in-draft archives need no migration). Each is paired with its
  # current mapping, if one was recorded as-we-go. Sourced from the edit-mode
  # graph (the archive is deferred from the published read model during draft).
  def retiring_capabilities
    @retiring_capabilities ||= begin
      mappings = mappings_by_from_stable_id

      graph_capabilities
        .select { |c| c.pending_archive && !c.added_in_draft }
        .map { |c| { capability: c, mapping: mappings[c.stable_id] } }
    end
  end

  # All capability nodes from the edit-mode graph, loaded once per request.
  def graph_capabilities
    @graph_capabilities ||= begin
      graph = Frameworks::ExplorerGraph.load(@framework.framework_id) ||
              Frameworks::ExplorerGraph.rebuild(@framework.framework_id)
      graph.capability_categories.flat_map(&:capabilities)
    end
  end

  def mappings_by_from_stable_id
    FrameworkState::MigrationMapping
      .where(framework_id: @framework.framework_id, published_version: @framework.draft_version)
      .index_by(&:from_stable_id)
  end

  # Capabilities that will exist post-publish (not being retired) — survivor
  # candidates for evolved/split mappings.
  def survivor_candidates
    graph_capabilities
      .reject(&:pending_archive)
      .map { |c| { name: c.name, stable_id: c.stable_id } }
      .sort_by { |c| c[:name] }
  end
end
