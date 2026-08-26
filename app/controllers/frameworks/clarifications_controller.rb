# frozen_string_literal: true

# Opens a discussion on a framework entity from the explorer's edit-mode
# "Discuss…" affordances (expectation cell, capability row kebab, illustration
# kebab) — a clarification: an anchored question that proposes nothing
# (framework-explorer.md §12a).
#
# Answers 204 with the new suggestion id in `X-Suggestion-Id` so the modal's
# form controller can open that discussion's card in the context pane. Bodyless
# by design — a Turbo submit that receives a bare 200 renders the empty body
# over the page (Hard-Won Lesson 21).
#
# Restricted to suggest-rights holders (FrameworkSuggestionPolicy#create?),
# which is the same bar edit mode itself requires.
class Frameworks::ClarificationsController < ApplicationController
  SUGGESTION_ID_HEADER = "X-Suggestion-Id"

  before_action :set_framework

  # POST /frameworks/:framework_id/clarifications
  def create
    authorize FrameworkState::SuggestedEdit.new(framework_id: @framework.framework_id), :create?

    result = Operations::Frameworks::RequestClarification.call(
      context: pundit_user,
      params: {
        framework_id: @framework.framework_id,
        capability_id: clarification_params[:capability_id].presence,
        illustration_id: clarification_params[:illustration_id].presence,
        level_ordinal: level_ordinal,
        rationale: clarification_params[:rationale].to_s
      }
    )

    response.set_header(SUGGESTION_ID_HEADER, result[:suggestion_id])
    head :no_content
  rescue Operations::Base::ParameterError, ActiveRecord::RecordNotFound, RuntimeError
    head :unprocessable_content
  end

  private

  def clarification_params
    @clarification_params ||=
      params.expect(clarification: [ :capability_id, :illustration_id, :level_ordinal, :rationale ])
  end

  # Blank means "the whole capability" (the row kebab's level select offers
  # that), so nil through rather than defaulting to a level the user didn't pick.
  # A non-numeric ordinal is a malformed submission, not a capability-wide ask.
  def level_ordinal
    raw = clarification_params[:level_ordinal].presence
    return nil if raw.nil?

    Integer(raw, exception: false) ||
      raise(Operations::Base::ParameterError, "level must be a number")
  end

  def set_framework
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:framework_id))
  rescue ActiveRecord::RecordNotFound
    redirect_to frameworks_path
  end
end
