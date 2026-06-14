# frozen_string_literal: true

# Serves the framework explorer's right-hand context pane as a full activity
# feed (the generalisation of the old suggestions-only panel). Renders the
# `suggestion-panel` Turbo Frame, narrowed by the same focus protocol the
# suggestion panel used (`focus / category_id / capability_id / level_ordinal`),
# driven by {Frameworks::ActivityFeedQuery}.
#
class Frameworks::ActivityController < ApplicationController
  before_action :set_framework

  # GET /frameworks/:framework_id/activity
  def show
    authorize @framework, :view_suggestions?

    query = Frameworks::ActivityFeedQuery.new(
      framework: @framework,
      focus: focus_param,
      category_id: params[:category_id].presence,
      capability_id: params[:capability_id].presence,
      level_ordinal: params[:level_ordinal].presence&.to_i
    )

    render Views::Frameworks::Activity::PanelFrame.new(
      framework: @framework,
      entries: query.call,
      focus_descriptor: query.descriptor,
      clear_path: framework_activity_path(@framework.framework_id, layout: "panel")
    ), layout: false
  end

  private

  def set_framework
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:framework_id))
  rescue ActiveRecord::RecordNotFound
    redirect_to frameworks_path
  end

  # @return [Symbol] one of Frameworks::ActivityFeedQuery::FOCUS_LEVELS
  def focus_param
    raw = params[:focus].to_s.to_sym
    Frameworks::ActivityFeedQuery::FOCUS_LEVELS.include?(raw) ? raw : :framework
  end
end
