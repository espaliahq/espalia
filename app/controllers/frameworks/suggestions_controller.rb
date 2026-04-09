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

    scope = @framework.suggested_edits
    scope = scope.where(status: status_filter) if status_filter.present?
    scope = scope.where(target_entity_type: entity_type_filter) if entity_type_filter.present?
    scope = scope.order(created_at: :desc)

    suggestions = scope.to_a

    if panel_layout?
      render Views::Frameworks::Suggestions::PanelFrame.new(
        framework: @framework, suggestions: suggestions
      ), layout: false
    else
      render Views::Frameworks::Suggestions::IndexView.new(
        framework: @framework,
        suggestions: suggestions,
        filters: { status: status_filter, entity_type: entity_type_filter },
        user: current_user,
        current_tenant: ActsAsTenant.current_tenant,
        tenants: tenants_for_navbar
      )
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

  # POST /frameworks/:framework_id/suggestions/:id/approve
  def approve
    authorize @suggestion, :approve?

    Frameworks::CommandHandler.new.approve_suggestion(
      @framework.framework_id,
      @suggestion.suggestion_id,
      current_user.id.to_s,
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
      current_user.id.to_s,
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
      current_user.id.to_s,
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
      @suggestion.suggestion_id
    )

    redirect_to framework_suggestions_path(@framework.framework_id),
                status: :see_other,
                notice: "Suggestion withdrawn."
  rescue RuntimeError => e
    redirect_to framework_suggestion_path(@framework.framework_id, @suggestion.suggestion_id),
                alert: e.message
  end

  private

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

  # @return [Array<Tenant>]
  def tenants_for_navbar
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end
end
