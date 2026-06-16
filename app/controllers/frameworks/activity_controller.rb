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
  #
  # Two response shapes:
  # - Turbo Frame / HTML (initial load, broadcast reload) → the full PanelFrame.
  # - Turbo Stream (the "load older" button, via @rails/request.js) → append the
  #   older batch to the list and swap the load-more footer for the next cursor.
  def show
    authorize @framework, :view_suggestions?

    query = Frameworks::ActivityFeedQuery.new(
      framework: @framework,
      focus: focus_param,
      category_id: params[:category_id].presence,
      capability_id: params[:capability_id].presence,
      level_ordinal: params[:level_ordinal].presence&.to_i,
      before: params[:before].presence
    )

    @entries = query.call
    @approval_authority = approval_authority
    # "Load older" is only meaningful for the unfiltered feed — a focused view is
    # already a small, recency-covered slice (avoids sparse/empty appended batches).
    @has_more = query.has_more? && query.focus == :framework
    @next_cursor = query.next_cursor
    # Running total of entries loaded so far (carried across batches via `loaded`)
    # so the header count stays accurate as older batches are appended.
    @total_loaded = params[:loaded].to_i + @entries.size
    @load_more_path = compute_load_more_path

    respond_to do |format|
      format.turbo_stream
      format.any do
        render Views::Frameworks::Activity::PanelFrame.new(
          framework: @framework,
          entries: @entries,
          focus_descriptor: query.descriptor,
          clear_path: framework_activity_path(@framework.framework_id, layout: "panel"),
          approval_authority: @approval_authority,
          has_more: @has_more,
          load_more_path: @load_more_path,
          total_loaded: @total_loaded
        ), layout: false
      end
    end
  end

  private

  # URL for the next (older) batch — preserves the active focus/role scope so
  # pagination stays within the same view.
  def compute_load_more_path
    return nil unless @has_more

    framework_activity_path(@framework.framework_id, **feed_scope_params,
      before: @next_cursor, loaded: @total_loaded)
  end

  # The focus/role params that scope the feed, echoed onto the load-more URL.
  def feed_scope_params
    {
      focus: params[:focus].presence,
      category_id: params[:category_id].presence,
      capability_id: params[:capability_id].presence,
      level_ordinal: params[:level_ordinal].presence,
      roles: Array.wrap(params[:roles]).select(&:present?).presence
    }.compact
  end

  # Per-viewer approval authority, computed once so the actionable feed never
  # instantiates a policy per pending-suggestion entry.
  def approval_authority
    Frameworks::SuggestionApprovalAuthority.for(
      framework_id: @framework.framework_id,
      person: current_person,
      tenant_admin: current_user&.global_admin? || current_tenant_user&.admin? || false
    )
  end

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
