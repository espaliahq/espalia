# frozen_string_literal: true

# Serves the framework explorer's right-hand context pane as a full activity
# feed (the generalisation of the old suggestions-only panel). Renders the
# `suggestion-panel` Turbo Frame, narrowed by the same focus protocol the
# suggestion panel used (`focus / category_id / capability_id / level_ordinal`),
# driven by {Frameworks::ActivityFeedQuery}.
#
class Frameworks::ActivityController < ApplicationController
  include Frameworks::SuggestionAuthority

  before_action :set_framework

  # GET /frameworks/:framework_id/activity
  #
  # Two response shapes:
  # - Turbo Frame / HTML (initial load, broadcast reload) → the full PanelFrame.
  # - Turbo Stream (the "load older" button, via @rails/request.js) → append the
  #   older batch to the list and swap the load-more footer for the next cursor.
  def show
    authorize @framework, :view_suggestions?

    # Suggestion focus swaps the pane from feed mode to one suggestion's
    # consolidated card (proposal + approve/reject + discussion thread) —
    # same Turbo Frame, different content.
    return render_suggestion_card if suggestion_focus?

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

  def suggestion_focus?
    params[:focus].to_s == "suggestion" && params[:suggestion_id].present?
  end

  # Renders the pane's suggestion card. An unknown suggestion (withdrawn from
  # under a stale link, wrong framework) falls back to the framework feed
  # rather than blanking the pane.
  def render_suggestion_card
    suggestion = FrameworkState::SuggestedEdit
      .where(framework_id: @framework.framework_id)
      .find_by(suggestion_id: params[:suggestion_id])
    return redirect_to framework_activity_path(@framework.framework_id, layout: "panel") if suggestion.nil?

    comments = FrameworkState::SuggestionComment
      .for_suggestion(suggestion.suggestion_id)
      .includes(:author)
      .chronological
      .to_a

    render Views::Frameworks::Activity::SuggestionCardFrame.new(
      framework: @framework,
      suggestion: suggestion,
      comments: comments,
      # A failed thread submission redirects back here inside the Turbo
      # Frame, which renders no layout — surface the alert in the card or
      # the rejection is silent.
      alert: flash[:alert],
      author_name: Person.find_by(id: suggestion.author_id)&.name,
      clear_path: framework_activity_path(@framework.framework_id, layout: "panel"),
      permalink: discussion_permalink(suggestion),
      siblings: sibling_discussions(suggestion),
      approval_authority: approval_authority,
      viewer_person_id: current_person&.id,
      can_comment: current_person.present? && policy(@framework).comment_on_suggestion?,
      tenant_admin: policy(@framework).admin?
    ), layout: false
  end

  # The other open discussions anchored on the same cell, so a card is never a
  # dead end when several share one glyph.
  #
  # Read straight from the read model rather than the activity feed: the feed is
  # capped at the newest STREAM_READ_LIMIT events (and can't page older while
  # focused), so routing "show me the rest" through it would silently lose
  # discussions older than that window. There is no such cap here.
  #
  # @param suggestion [FrameworkState::SuggestedEdit]
  # @return [Array<FrameworkState::SuggestedEdit>] oldest first, never the
  #   suggestion itself
  def sibling_discussions(suggestion)
    return [] unless suggestion.clarification?

    entity_ids = cell_entity_ids(suggestion)
    return [] if entity_ids.empty?

    FrameworkState::SuggestedEdit
      .where(framework_id: @framework.framework_id, target_entity_id: entity_ids)
      .clarifications.pending
      .where.not(suggestion_id: suggestion.suggestion_id)
      .order(:created_at, :id)
      .to_a
  end

  # Every entity whose discussions belong to the same cell as this suggestion —
  # the expectation plus its illustrations, mirroring how the cell glyph counts
  # them. A capability-anchored question (no expectation) stands alone.
  #
  # @return [Array<String>]
  def cell_entity_ids(suggestion)
    expectation_id =
      case suggestion.target_entity_type
      when "behavioural_expectation" then suggestion.target_entity_id
      when "role_illustration"
        FrameworkState::RoleIllustration
          .find_by(illustration_id: suggestion.target_entity_id)&.expectation_id
      end
    return [ suggestion.target_entity_id ] if expectation_id.nil?

    [ expectation_id ] + FrameworkState::RoleIllustration
      .where(expectation_id: expectation_id).pluck(:illustration_id)
  end

  # A shareable link straight to this discussion — the explorer deep link, not
  # the standalone suggestion page, so whoever opens it lands on the discussion
  # WITH the framework loaded around it (the grid context is usually the point
  # of sharing an anchored question). `context_pane_controller#hydrateFromUrl`
  # reads these params on connect and opens the card.
  #
  # Built from `request.base_url` so the link carries whichever host the sharer
  # is actually on, rather than a configured canonical that may not match.
  #
  # @param suggestion [FrameworkState::SuggestedEdit]
  # @return [String]
  def discussion_permalink(suggestion)
    request.base_url + edit_framework_path(
      @framework.framework_id, focus: "suggestion", suggestion_id: suggestion.suggestion_id
    )
  end

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
    framework_suggestion_approval_authority
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
