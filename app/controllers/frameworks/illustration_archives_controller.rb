# frozen_string_literal: true

# Archives (removes) a role illustration from the explorer's edit-mode
# expanded-row affordance. Like the capability archive kebab, the Operation
# decides — from the edit/suggest toggle + the actor's authority — whether the
# removal applies directly or lands as a pending suggestion, so the affordance
# is offered to any suggest-rights holder. Illustrations carry no ratings, so
# there's no migration mapping.
#
# Restricted to suggest-rights holders via FrameworkPolicy#suggest_edit?.
class Frameworks::IllustrationArchivesController < ApplicationController
  include FrameworkEditMode
  include Frameworks::SuggestionAuthority
  include Frameworks::IllustrationFrameContext
  include Frameworks::WriteResponse

  before_action :set_framework
  before_action :set_illustration

  # POST /frameworks/:framework_id/illustration_archives
  def create
    authorize @framework, :suggest_edit?

    result = Operations::Frameworks::ArchiveIllustration.call(
      context: pundit_user,
      params: {
        framework_id: @framework.framework_id,
        illustration_id: @illustration.illustration_id,
        reason: archive_params[:reason].presence,
        mode: framework_edit_mode.to_s
      }
    )

    if result[:archived]
      # Gone from the grid — remove its frame from the expanded row it sits in.
      # (Illustrations carry no ratings, so removal is immediate, not deferred
      # to publish; there is no draft status to stream.)
      render_write_streams([
        toast_stream("Archived the example."),
        turbo_stream.remove("illustration-#{@illustration.illustration_id}")
      ])
    else
      render_write_streams(
        [ toast_stream("Proposed removing the example for review.") ] +
        illustration_frame_streams
      )
    end
  rescue Operations::Base::ParameterError, RuntimeError, ActiveRecord::RecordNotFound => e
    # RecordNotFound covers a stale / concurrent submit or a cross-framework
    # id that the framework-scoped Operation lookup rejects — surface it in the
    # toast rather than a 500 (or a navigation that costs the open row).
    render_write_error(e.message)
  end

  private

  def archive_params
    @archive_params ||= params.expect(archive: [ :illustration_id, :reason ])
  end

  def set_framework
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:framework_id))
  rescue ActiveRecord::RecordNotFound
    redirect_to frameworks_path
  end

  def set_illustration
    @illustration = FrameworkState::RoleIllustration.find_by(illustration_id: archive_params[:illustration_id])
    render_write_error("that example no longer exists — reload the page") unless @illustration
  end

  # A *proposed* removal leaves the illustration on the grid; re-render its
  # frame so the pending decoration lands immediately (Hard-Won Lesson 16), with
  # the discussion context re-threaded (Lesson 13).
  def illustration_frame_streams
    [ turbo_stream.replace(
      "illustration-#{@illustration.illustration_id}",
      render_to_string(
        Views::Frameworks::Explorer::IllustrationFrame.new(
          illustration: @illustration,
          framework_id: @framework.framework_id,
          mode: :edit,
          pending_edit_count: pending_illustration_proposal_count,
          can_reorder: policy(@framework).reorder_illustrations?,
          approval_authority: framework_suggestion_approval_authority,
          discuss_context_label: illustration_discuss_context_label(@illustration),
          clarification: illustration_clarification(@illustration)
        ),
        layout: false
      )
    ) ]
  end

  def pending_illustration_proposal_count
    FrameworkState::SuggestedEdit.where(
      framework_id: @framework.framework_id,
      target_entity_type: "role_illustration",
      target_entity_id: @illustration.illustration_id,
      status: "pending"
    ).proposals.count
  end
end
