# frozen_string_literal: true

# Reviewer surface for inline framework suggested edits.
#
# Lists pending and resolved suggestions for a framework, lets reviewers with
# the appropriate tier authority approve / reject, and lets authors amend or
# withdraw their own pending suggestions. Every write dispatches an
# {Operations::Frameworks} class (web + MCP parity); all tier rules are
# enforced via {FrameworkSuggestionPolicy}.
#
class Frameworks::SuggestionsController < ApplicationController
  include Frameworks::SuggestionAuthority
  include Frameworks::SuggestionResolutionStreams
  include Frameworks::IllustrationFrameContext

  before_action :set_framework
  before_action :set_suggestion, only: [ :show, :approve, :reject, :resolve, :amend, :destroy ]

  # GET /frameworks/:framework_id/suggestions
  def index
    authorize @framework, :view_suggestions?

    if panel_layout?
      render_panel
    else
      render_index
    end
  end

  # GET /frameworks/:framework_id/suggestions/:id
  def show
    authorize @suggestion, :show?

    render Views::Frameworks::Suggestions::ShowView.new(
      framework: @framework,
      suggestion: @suggestion,
      can_approve: policy(@suggestion).approve?,
      can_amend: policy(@suggestion).amend?,
      can_withdraw: policy(@suggestion).withdraw?,
      can_resolve: policy(@suggestion).resolve?,
      comments: FrameworkState::SuggestionComment
        .for_suggestion(@suggestion.suggestion_id).includes(:author).chronological.to_a,
      viewer_person_id: current_person&.id,
      can_comment: current_person.present? && policy(@framework).comment_on_suggestion?,
      tenant_admin: policy(@framework).admin?,
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: tenants_for_navbar
    )
  end

  # POST /frameworks/:framework_id/suggestions
  #
  # Submits a create- or delete-kind suggestion as a pending proposal. The
  # suggestion always lands in pending state — even if the author has approval
  # authority — because this controller is the "propose a change" endpoint,
  # not the "make a change" endpoint. Approvers use the existing approve action
  # to apply the change. Edit-kind suggestions are submitted by per-entity
  # controllers (e.g. IllustrationsController) via
  # {Operations::Frameworks::SuggestEdit}.
  def create
    authorize @framework, :submit_suggestion?

    attrs = suggestion_create_params

    result =
      case attrs[:kind]
      when "create"
        Operations::Frameworks::SuggestCreate.call(
          context: pundit_user,
          params: {
            framework_id: @framework.framework_id,
            entity_type: attrs[:target_entity_type],
            proposed_attributes: (attrs[:proposed_attributes] || {}).to_h,
            parent_id: attrs[:parent_id].presence,
            rationale: attrs[:rationale].presence,
            mode: "suggesting"
          }
        )
      when "delete"
        Operations::Frameworks::SuggestDelete.call(
          context: pundit_user,
          params: {
            framework_id: @framework.framework_id,
            entity_type: attrs[:target_entity_type],
            entity_id: attrs[:target_entity_id],
            rationale: attrs[:rationale].presence
          }
        )
      else
        return redirect_to framework_suggestions_path(@framework.framework_id),
                           status: :see_other,
                           alert: "Unknown suggestion kind: #{attrs[:kind]}"
      end

    redirect_to framework_suggestion_path(@framework.framework_id, result[:suggestion_id]),
                notice: "Suggestion submitted."
  rescue ActiveRecord::RecordNotFound, Operations::Base::ParameterError, RuntimeError => e
    redirect_to framework_suggestions_path(@framework.framework_id),
                status: :see_other,
                alert: e.message
  end

  # POST /frameworks/:framework_id/suggestions/:id/approve
  #
  # HTML (detail page) → redirect. Inline (feed / grid, `inline=1`) → a
  # surgical Turbo Stream replacing just the affected entity's frame when the
  # suggestion's shape supports it, else 204 (the client falls back to a full
  # matrix refresh). The feed reloads itself off the activity broadcast — see
  # framework-explorer.md (actionable feed).
  def approve
    authorize @suggestion, :approve?

    Operations::Frameworks::ApproveSuggestion.call(
      context: pundit_user,
      params: {
        framework_id: @framework.framework_id,
        suggestion_id: @suggestion.suggestion_id,
        comment: params[:comment].presence
      }
    )

    respond_to_resolution(notice: "Suggestion approved.", outcome: :approved)
  rescue Operations::Base::ParameterError, RuntimeError => e
    respond_to_failure(e)
  end

  # POST /frameworks/:framework_id/suggestions/:id/reject
  def reject
    authorize @suggestion, :reject?

    Operations::Frameworks::RejectSuggestion.call(
      context: pundit_user,
      params: {
        framework_id: @framework.framework_id,
        suggestion_id: @suggestion.suggestion_id,
        comment: params[:comment].presence
      }
    )

    respond_to_resolution(notice: "Suggestion rejected.", outcome: :rejected)
  rescue Operations::Base::ParameterError, RuntimeError => e
    respond_to_failure(e)
  end

  # POST /frameworks/:framework_id/suggestions/:id/resolve
  #
  # Resolves a clarification with a note — the non-proposal kind's terminal
  # verb (approve/reject never apply to it). Same inline-vs-redirect split as
  # approve/reject.
  def resolve
    authorize @suggestion, :resolve?

    Operations::Frameworks::ResolveClarification.call(
      context: pundit_user,
      params: {
        framework_id: @framework.framework_id,
        suggestion_id: @suggestion.suggestion_id,
        note: params[:note].to_s,
        resulting_suggestion_id: params[:resulting_suggestion_id].presence
      }
    )

    respond_to_resolution(notice: "Clarification resolved.")
  rescue Operations::Base::ParameterError, RuntimeError => e
    respond_to_failure(e)
  end

  # PATCH /frameworks/:framework_id/suggestions/:id/amend
  def amend
    authorize @suggestion, :amend?

    amendment = params.expect(suggestion: [ :suggested_value, :rationale ])

    Operations::Frameworks::AmendSuggestion.call(
      context: pundit_user,
      params: {
        framework_id: @framework.framework_id,
        suggestion_id: @suggestion.suggestion_id,
        suggested_value: amendment[:suggested_value],
        rationale: amendment[:rationale].presence
      }
    )

    if inline_ghost_request?
      # The matrix ghost's amend form lives inside the pending-suggestion
      # Turbo Frame — re-render it in place with the amended value. The
      # detail-page redirect would land on a page with no matching frame
      # ("Content missing"). Lesson 20: explicit inline marker, not format.
      render_pending_ghost_frame
    elsif inline_request?
      # Some future inline surface that isn't the illustration ghost —
      # never answer it with an illustration-shaped frame.
      head :no_content
    else
      redirect_to framework_suggestion_path(@framework.framework_id, @suggestion.suggestion_id),
                  notice: "Suggestion updated."
    end
  rescue Operations::Base::ParameterError, RuntimeError => e
    if inline_ghost_request?
      # A bodyless 4xx would blank the ghost's frame to "Content missing" —
      # re-render it with the error surfaced instead.
      render_pending_ghost_frame(error: e.message, status: :unprocessable_content)
    elsif inline_request?
      head :unprocessable_content
    else
      redirect_to framework_suggestion_path(@framework.framework_id, @suggestion.suggestion_id),
                  alert: e.message
    end
  end

  # DELETE /frameworks/:framework_id/suggestions/:id
  def destroy
    authorize @suggestion, :withdraw?

    Operations::Frameworks::WithdrawSuggestion.call(
      context: pundit_user,
      params: {
        framework_id: @framework.framework_id,
        suggestion_id: @suggestion.suggestion_id
      }
    )

    redirect_to framework_suggestions_path(@framework.framework_id),
                status: :see_other,
                notice: "Suggestion withdrawn."
  rescue Operations::Base::ParameterError, RuntimeError => e
    redirect_to framework_suggestion_path(@framework.framework_id, @suggestion.suggestion_id),
                alert: e.message
  end

  private

  # Approve/reject are reachable both from the suggestion detail page (wants a
  # redirect + flash) and from the inline activity feed / matrix grid. The
  # inline surfaces flag themselves with `inline=1`; everything else (incl.
  # the Turbo-driven detail page) redirects. An inline resolution answers a
  # surgical Turbo Stream replacing the affected entity's frame when the shape
  # supports it (see {Frameworks::SuggestionResolutionStreams}); otherwise 204
  # — which keeps Turbo from navigating or blanking the modal/page, and tells
  # the client to fall back to a full matrix refresh. The feed always reloads
  # off the activity broadcast.
  # The pending-illustration ghost's amend form — the one inline surface
  # whose response contract is "re-render my frame". Guarded by shape so a
  # different suggestion kind carrying inline=1 never gets an
  # illustration-shaped frame.
  def inline_ghost_request?
    inline_request? &&
      @suggestion.kind == "create" &&
      @suggestion.target_entity_type == "role_illustration"
  end

  def render_pending_ghost_frame(error: nil, status: :ok)
    render Views::Frameworks::Explorer::PendingIllustrationFrame.new(
      suggestion: @suggestion.reload,
      framework_id: @framework.framework_id,
      # amend? is author-only, so the requester is the author.
      is_author: true,
      error: error,
      # The frame swap must not drop the approval kebab (Lesson 13/16 class).
      approval_authority: framework_suggestion_approval_authority
    ), layout: false, status: status
  end

  def inline_request?
    params[:inline].present?
  end

  def respond_to_resolution(notice:, outcome: nil)
    unless inline_request?
      return redirect_to framework_suggestions_path(@framework.framework_id), notice: notice
    end

    streams = outcome ? resolution_streams(outcome: outcome) : nil
    if streams.present?
      render turbo_stream: streams
    else
      head :no_content
    end
  end

  def respond_to_failure(error)
    if inline_request?
      # Bodyless: neither inline client renders the message (the approve
      # button restores itself; the reject modal stays open), and a text/plain
      # body would be rendered AS the document by a Turbo form submit —
      # blanking the page (Hard-Won Lesson 21's failure class).
      head :unprocessable_content
    else
      redirect_to framework_suggestion_path(@framework.framework_id, @suggestion.suggestion_id),
                  alert: error.message
    end
  end

  def render_index
    scope = @framework.suggested_edits
    scope = scope.where(status: status_filter) if status_filter.present?
    scope = scope.where(target_entity_type: entity_type_filter) if entity_type_filter.present?
    scope = scope.order(created_at: :desc)

    render Views::Frameworks::Suggestions::IndexView.new(
      framework: @framework,
      suggestions: scope.to_a,
      filters: { status: status_filter, entity_type: entity_type_filter },
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: tenants_for_navbar
    )
  end

  def render_panel
    query = Frameworks::FocusedSuggestionsQuery.new(
      framework: @framework,
      focus: focus_param,
      category_id: params[:category_id].presence,
      capability_id: params[:capability_id].presence,
      level_ordinal: params[:level_ordinal].presence&.to_i,
      role_ids: Array.wrap(params[:roles]).select(&:present?)
    )

    suggestions = query.call

    render Views::Frameworks::Suggestions::PanelFrame.new(
      framework: @framework,
      suggestions: suggestions,
      focus_descriptor: query.descriptor,
      context_labels: query.context_labels(suggestions),
      navigation_coords: query.navigation_coords(suggestions),
      clear_path: framework_suggestions_path(@framework.framework_id, layout: "panel")
    ), layout: false
  end

  def suggestion_create_params
    params.expect(suggestion: [
      :kind, :target_entity_type, :target_entity_id,
      :parent_id, :rationale,
      { proposed_attributes: {} }
    ])
  end

  def set_framework
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:framework_id))
  rescue ActiveRecord::RecordNotFound
    redirect_to frameworks_path
  end

  def set_suggestion
    @suggestion = @framework.suggested_edits.find_by!(suggestion_id: params.expect(:id))
  rescue ActiveRecord::RecordNotFound
    redirect_to framework_suggestions_path(@framework.framework_id),
                alert: "Suggestion not found."
  end

  # @return [String, nil]
  def status_filter
    params[:status].presence_in(FrameworkState::SuggestedEdit::STATUSES)
  end

  # @return [String, nil]
  def entity_type_filter
    params[:entity_type].presence
  end

  # @return [Boolean]
  def panel_layout?
    params[:layout] == "panel"
  end

  # @return [Symbol] one of Frameworks::FocusedSuggestionsQuery::FOCUS_LEVELS
  def focus_param
    raw = params[:focus].to_s.to_sym
    Frameworks::FocusedSuggestionsQuery::FOCUS_LEVELS.include?(raw) ? raw : :framework
  end

  # @return [Array<Tenant>]
  def tenants_for_navbar
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end
end
