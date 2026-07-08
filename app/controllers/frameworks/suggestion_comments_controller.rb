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

  rescue_from ActiveRecord::RecordNotFound do
    redirect_to thread_path, alert: "Comment or suggestion not found.", status: :see_other
  end
  rescue_from Operations::Base::ParameterError, RuntimeError do |e|
    redirect_to thread_path, alert: e.message, status: :see_other
  end
  # Two collaborators writing to the same framework stream at once — chat
  # cadence makes this collision far likelier than for structural edits.
  # RES raises WrongExpectedEventVersion (a StandardError, NOT a
  # RuntimeError), which would otherwise surface as a 500.
  rescue_from RubyEventStore::WrongExpectedEventVersion do
    redirect_to thread_path, status: :see_other,
                alert: "Someone else updated this framework at the same moment — please try again."
  end

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
  end

  # PATCH /frameworks/:framework_id/suggestions/:suggestion_id/comments/:id
  def update
    authorize comment, :update?, policy_class: FrameworkSuggestionCommentPolicy

    Operations::Frameworks::EditSuggestionComment.call(
      context: pundit_user,
      params: {
        framework_id: @framework.framework_id,
        comment_id: comment.id,
        body: params.expect(comment: [ :body ])[:body].to_s
      }
    )
    redirect_to thread_path, notice: "Comment updated."
  end

  # DELETE /frameworks/:framework_id/suggestions/:suggestion_id/comments/:id
  def destroy
    authorize comment, :destroy?, policy_class: FrameworkSuggestionCommentPolicy

    Operations::Frameworks::DeleteSuggestionComment.call(
      context: pundit_user,
      params: {
        framework_id: @framework.framework_id,
        comment_id: comment.id
      }
    )
    redirect_to thread_path, notice: "Comment deleted.", status: :see_other
  end

  private

  def set_framework
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:framework_id))
  rescue ActiveRecord::RecordNotFound
    redirect_to frameworks_path
  end

  # Scoped to the framework AND the URL's suggestion so a comment id from a
  # different thread reads as not-found rather than mutating a record the
  # redirect target won't show.
  def comment
    @comment ||= FrameworkState::SuggestionComment
      .for_framework(@framework.framework_id)
      .for_suggestion(params.expect(:suggestion_id))
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
