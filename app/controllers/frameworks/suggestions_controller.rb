# frozen_string_literal: true

# Reviewer surface for inline framework suggested edits.
#
# Lists pending and resolved suggestions for a framework, lets reviewers with
# the appropriate tier authority approve / reject, and lets authors amend or
# withdraw their own pending suggestions. Acts as a thin wrapper around
# {Frameworks::CommandHandler}; all tier rules are enforced via
# {FrameworkSuggestionPolicy}.
#
class Frameworks::SuggestionsController < ApplicationController
  before_action :set_framework
  before_action :set_suggestion, only: [ :show, :approve, :reject, :amend, :destroy ]

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
  # controllers (e.g. IllustrationsController) which call
  # Frameworks::CommandHandler#suggest_edit directly.
  def create
    authorize @framework, :submit_suggestion?

    attrs = suggestion_create_params
    suggestion_id = SecureRandom.uuid_v7
    handler = Frameworks::CommandHandler.new

    case attrs[:kind]
    when "create"
      handler.suggest_create(
        @framework.framework_id, suggestion_id,
        attrs[:target_entity_type],
        (attrs[:proposed_attributes] || {}).to_h.symbolize_keys,
        parent_id: attrs[:parent_id].presence,
        author_id: current_person.id.to_s,
        rationale: attrs[:rationale].presence,
        mode: :suggesting
      )
    when "delete"
      handler.suggest_delete(
        @framework.framework_id, suggestion_id,
        attrs[:target_entity_type], attrs[:target_entity_id],
        author_id: current_person.id.to_s,
        rationale: attrs[:rationale].presence,
        mode: :suggesting
      )
    else
      return redirect_to framework_suggestions_path(@framework.framework_id),
                         status: :see_other,
                         alert: "Unknown suggestion kind: #{attrs[:kind]}"
    end

    redirect_to framework_suggestion_path(@framework.framework_id, suggestion_id),
                notice: "Suggestion submitted."
  rescue RuntimeError => e
    redirect_to framework_suggestions_path(@framework.framework_id),
                status: :see_other,
                alert: e.message
  end

  # POST /frameworks/:framework_id/suggestions/:id/approve
  def approve
    authorize @suggestion, :approve?

    Frameworks::CommandHandler.new.approve_suggestion(
      @framework.framework_id,
      @suggestion.suggestion_id,
      current_person.id.to_s,
      comment: params[:comment].presence
    )

    redirect_to framework_suggestions_path(@framework.framework_id),
                notice: "Suggestion approved."
  rescue RuntimeError => e
    redirect_to framework_suggestion_path(@framework.framework_id, @suggestion.suggestion_id),
                alert: e.message
  end

  # POST /frameworks/:framework_id/suggestions/:id/reject
  def reject
    authorize @suggestion, :reject?

    Frameworks::CommandHandler.new.reject_suggestion(
      @framework.framework_id,
      @suggestion.suggestion_id,
      current_person.id.to_s,
      comment: params[:comment].presence
    )

    redirect_to framework_suggestions_path(@framework.framework_id),
                notice: "Suggestion rejected."
  rescue RuntimeError => e
    redirect_to framework_suggestion_path(@framework.framework_id, @suggestion.suggestion_id),
                alert: e.message
  end

  # PATCH /frameworks/:framework_id/suggestions/:id/amend
  def amend
    authorize @suggestion, :amend?

    amendment = params.expect(suggestion: [ :suggested_value, :rationale ])

    Frameworks::CommandHandler.new.amend_suggestion(
      @framework.framework_id,
      @suggestion.suggestion_id,
      amendment[:suggested_value],
      current_person.id.to_s,
      rationale: amendment[:rationale].presence
    )

    redirect_to framework_suggestion_path(@framework.framework_id, @suggestion.suggestion_id),
                notice: "Suggestion updated."
  rescue RuntimeError => e
    redirect_to framework_suggestion_path(@framework.framework_id, @suggestion.suggestion_id),
                alert: e.message
  end

  # DELETE /frameworks/:framework_id/suggestions/:id
  def destroy
    authorize @suggestion, :withdraw?

    Frameworks::CommandHandler.new.withdraw_suggestion(
      @framework.framework_id,
      @suggestion.suggestion_id,
      current_person.id.to_s
    )

    redirect_to framework_suggestions_path(@framework.framework_id),
                status: :see_other,
                notice: "Suggestion withdrawn."
  rescue RuntimeError => e
    redirect_to framework_suggestion_path(@framework.framework_id, @suggestion.suggestion_id),
                alert: e.message
  end

  private

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

    render Views::Frameworks::Suggestions::PanelFrame.new(
      framework: @framework,
      suggestions: query.call,
      focus_descriptor: query.descriptor,
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
