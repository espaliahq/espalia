# frozen_string_literal: true

# Publishes the current draft of a framework as a new version.
#
# The web is the in-app confirmation surface for the otherwise :in_app
# {Operations::Frameworks::PublishVersion}, so it dispatches the operation
# directly (behind a Turbo confirm dialog in the explorer header). Restricted
# to owners / editors and tenant admins via FrameworkPolicy#publish?.
class Frameworks::PublicationsController < ApplicationController
  before_action :set_framework

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
end
