# frozen_string_literal: true

# The web surface for publishing a framework's current draft.
#
# `new` is the review page — what the version changes, every capability being
# retired with its migration mapping, and the state of the latest publish
# request. `create`
# dispatches {Operations::Frameworks::PublishVersion}, which checks the
# publish gate, records a {FrameworkPublication} and enqueues the background
# job; the same operation serves an MCP agent's in-app approval, so both
# surfaces share one implementation and one in-flight lock. Restricted to
# owners / editors and tenant admins via FrameworkPolicy#publish?.
class Frameworks::PublicationsController < ApplicationController
  before_action :set_framework
  before_action :require_draft

  # GET /frameworks/:framework_id/publication/new
  def new
    authorize @framework, :publish?

    retiring = Frameworks::RetiringCapabilitiesQuery.new(@framework)
    render Views::Frameworks::PublicationReviewView.new(
      framework: @framework,
      retiring: retiring.call,
      survivors: retiring.survivors,
      changes: Operations::Frameworks::DraftChanges.call(
        context: pundit_user, params: { framework_id: @framework.framework_id }
      )[:changes],
      publication: FrameworkPublication.latest_for(@framework.framework_id, @framework.draft_version),
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
                notice: "Publishing v#{result[:draft_version]} in the background — " \
                        "you'll be notified when it's live."
  rescue RuntimeError => e
    # The operation's refusals are authored for the user; the review page is
    # where they can act on any of them.
    redirect_to new_framework_publication_path(@framework.framework_id), alert: e.message
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
    return if @framework.draft?

    redirect_to edit_framework_path(@framework.framework_id), alert: "No draft in progress."
  end
end
