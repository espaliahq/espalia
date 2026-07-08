# frozen_string_literal: true

# Handles suggestion discussion-thread submissions — post / edit / delete —
# from the two thread surfaces: the context pane's suggestion card (the
# primary workspace) and the suggestion detail page (the full-page escape
# hatch). Both dispatch the shared Operations::Frameworks::* the MCP tools
# use; `return_to=detail` routes the redirect back to the detail page,
# everything else re-renders the pane card in place (the redirect target
# renders the same `suggestion-panel` Turbo Frame the form lives in).
#
class Frameworks::SuggestionCommentsController < ApplicationController
  before_action :set_framework

  # POST /frameworks/:framework_id/suggestions/:suggestion_id/comments
  def create
    authorize @framework, :comment_on_suggestion?
    p = params.expect(comment: [ :body, :parent_id ])

    Operations::Frameworks::CommentOnSuggestion.call(
      context: pundit_user,
      params: {
        framework_id: @framework.framework_id,
        suggestion_id: params.expect(:suggestion_id),
        body: p[:body].to_s,
        parent_id: p[:parent_id].presence
      }
    )
    redirect_to thread_path, notice: "Comment posted."
  rescue ActiveRecord::RecordNotFound
    redirect_to thread_path, alert: "Suggestion not found."
  rescue Operations::Base::ParameterError, RuntimeError => e
    redirect_to thread_path, alert: e.message
  end

  # PATCH /frameworks/:framework_id/suggestions/:suggestion_id/comments/:id
  def update
    authorize comment, :update?, policy_class: FrameworkSuggestionCommentPolicy

    Operations::Frameworks::EditSuggestionComment.call(
      context: pundit_user,
      params: {
        framework_id: @framework.framework_id,
        comment_id: params.expect(:id),
        body: params.expect(comment: [ :body ])[:body].to_s
      }
    )
    redirect_to thread_path, notice: "Comment updated."
  rescue ActiveRecord::RecordNotFound
    redirect_to thread_path, alert: "Comment not found."
  rescue Operations::Base::ParameterError, RuntimeError => e
    redirect_to thread_path, alert: e.message
  end

  # DELETE /frameworks/:framework_id/suggestions/:suggestion_id/comments/:id
  def destroy
    authorize comment, :destroy?, policy_class: FrameworkSuggestionCommentPolicy

    Operations::Frameworks::DeleteSuggestionComment.call(
      context: pundit_user,
      params: {
        framework_id: @framework.framework_id,
        comment_id: params.expect(:id)
      }
    )
    redirect_to thread_path, notice: "Comment deleted."
  rescue ActiveRecord::RecordNotFound
    redirect_to thread_path, alert: "Comment not found."
  rescue Operations::Base::ParameterError, RuntimeError => e
    redirect_to thread_path, alert: e.message
  end

  private

  def set_framework
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:framework_id))
  rescue ActiveRecord::RecordNotFound
    redirect_to frameworks_path
  end

  def comment
    @comment ||= FrameworkState::SuggestionComment
      .for_framework(@framework.framework_id)
      .find(params.expect(:id))
  end

  # Where the thread lives for this submission: the detail page, or the
  # pane's suggestion card (whose URL renders the same Turbo Frame the
  # form sits in, so Turbo swaps the card in place).
  def thread_path
    if params[:return_to] == "detail"
      framework_suggestion_path(@framework.framework_id, params[:suggestion_id])
    else
      framework_activity_path(@framework.framework_id,
                              focus: "suggestion",
                              suggestion_id: params[:suggestion_id],
                              layout: "panel")
    end
  end
end
