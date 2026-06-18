# frozen_string_literal: true

# Archives (removes) a role illustration from the explorer's edit-mode
# expanded-row affordance. Like the capability archive kebab, the Operation
# decides — from the edit/suggest toggle + the actor's authority — whether the
# removal applies directly or lands as a pending suggestion, so the affordance
# is offered to any suggest-rights holder. Illustrations carry no ratings, so
# there's no migration mapping.
#
# Restricted to suggest-rights holders via FrameworkPolicy#suggest_edit?.
class Frameworks::IllustrationArchivesController < ApplicationController
  include FrameworkEditMode

  before_action :set_framework
  before_action :set_illustration

  # POST /frameworks/:framework_id/illustration_archives
  def create
    authorize @framework, :suggest_edit?

    result = Operations::Frameworks::ArchiveIllustration.call(
      context: pundit_user,
      params: {
        framework_id: @framework.framework_id,
        illustration_id: @illustration.illustration_id,
        reason: archive_params[:reason].presence,
        mode: framework_edit_mode.to_s
      }
    )

    notice = result[:archived] ? "Archived the illustration." : "Proposed archiving the illustration."
    redirect_to edit_framework_path(@framework.framework_id), notice: notice
  rescue Operations::Base::ParameterError, RuntimeError => e
    redirect_to edit_framework_path(@framework.framework_id), alert: e.message
  end

  private

  def archive_params
    @archive_params ||= params.expect(archive: [ :illustration_id, :reason ])
  end

  def set_framework
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:framework_id))
  rescue ActiveRecord::RecordNotFound
    redirect_to frameworks_path
  end

  def set_illustration
    @illustration = FrameworkState::RoleIllustration.find_by(illustration_id: archive_params[:illustration_id])
    redirect_to edit_framework_path(@framework.framework_id) unless @illustration
  end
end
