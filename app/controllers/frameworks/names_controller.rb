# frozen_string_literal: true

# Renames a framework from the explorer's edit-mode header — the inline pencil
# on the page's `<h1>` ({Views::Frameworks::Explorer::FrameworkNameFrame}).
#
# A **direct** edit (shape-preserving, applied live), like the org-structure
# renames: no suggested-edit path, no pending decoration. Gated by
# FrameworkPolicy#rename? (see authorization.md) and dispatched through the
# shared Operations::Frameworks::Rename so the web and the `frameworks_rename`
# MCP tool are one implementation.
#
# A rejected save answers 422 WITH the frame — the message inline plus the
# attempted value echoed back so the editor re-opens with it (Hard-Won Lesson
# 26: a bodyless 4xx inside a Turbo Frame is invisible to the user).
#
class Frameworks::NamesController < ApplicationController
  before_action :set_framework

  # PATCH /frameworks/:framework_id/name
  def update
    authorize @framework, :rename?

    attempted = params.expect(framework: [ :name ])[:name].to_s
    # The Operation would refuse a blank too, but with the parameter boundary's
    # developer-facing wording; this is the copy the sibling inline editors show.
    return render_save_error("the name can’t be blank", attempted) if attempted.blank?

    result = Operations::Frameworks::Rename.call(
      context: pundit_user,
      params: { framework_id: @framework.framework_id, name: attempted }
    )

    render_name_frame(result[:name])
  rescue Operations::Base::ParameterError, RuntimeError => e
    render_save_error(e.message, attempted)
  end

  private

  # A rejected save (error present) re-renders the same frame at 422.
  def render_name_frame(name, error: nil, attempted_value: nil)
    render Views::Frameworks::Explorer::FrameworkNameFrame.new(
      framework_id: @framework.framework_id,
      name: name,
      mode: :edit,
      # Just authorized above — pass the policy's answer, not a literal, so
      # the re-render and the page render take identical inputs.
      can_rename: policy(@framework).rename?,
      error: error,
      attempted_value: attempted_value
    ), layout: false, status: (error ? :unprocessable_content : :ok)
  end

  def render_save_error(message, attempted_value)
    render_name_frame(@framework.name, error: message, attempted_value: attempted_value)
  end

  def set_framework
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:framework_id))
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end
end
