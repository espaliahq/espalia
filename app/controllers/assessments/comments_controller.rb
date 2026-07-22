# frozen_string_literal: true

# Posts, edits, and soft-deletes comments on a person's assessment.
#
# Serves both commentable types: `"assessment_cell"` (the default) and
# `"evidence_link"` (selected by the presence of `comment[evidence_id]`
# on create; on update/destroy the comment row itself carries the type).
# Evidence-link requests originate inside the linkage's thread frame, so
# their responses redirect to the frame's show URL — Turbo re-renders
# the thread in place — instead of the full assessment page. Future
# commentable types (growth plans, focus areas, check-ins) will add
# their own shape here.
#
class Assessments::CommentsController < ApplicationController
  before_action :require_person
  before_action :set_assignment

  # POST /assessments/:assessment_id/comments
  def create
    authorize @assignment, :create?, policy_class: PersonDevelopmentCommentPolicy

    attrs = params.expect(comment: [
      :capability_stable_id, :level_ordinal, :body, :parent_id, :evidence_id
    ])
    evidence_id = attrs[:evidence_id].presence

    level_ordinal = Integer(attrs[:level_ordinal], exception: false)
    # For evidence_link comments the coordinate's validity is the
    # aggregate's ever-linked check — the level need not exist on the
    # viewer's role (a manager may have linked at any ordinal).
    unless level_ordinal && (evidence_id ||
        FrameworkState::Level.exists?(role_id: @assignment.role_id, ordinal: level_ordinal))
      head :unprocessable_content
      return
    end

    if attrs[:body].to_s.strip.empty?
      comment_error(evidence_id, attrs[:capability_stable_id], level_ordinal,
        "Comment cannot be blank.")
      return
    end

    comment_id = SecureRandom.uuid_v7
    PersonDevelopment::CommandHandler.new.post_comment(
      @assignment.person_id, @assignment.framework_id, comment_id,
      commentable_type: evidence_id ? PersonDevelopmentComment::EVIDENCE_LINK
                                    : PersonDevelopmentComment::ASSESSMENT_CELL,
      capability_stable_id: attrs[:capability_stable_id],
      level_ordinal: level_ordinal,
      evidence_id: evidence_id,
      body: attrs[:body].to_s,
      author_id: current_person.id,
      parent_id: attrs[:parent_id].presence
    )

    if evidence_id
      redirect_to link_thread_path(evidence_id, attrs[:capability_stable_id], level_ordinal),
        status: :see_other
    else
      redirect_to assessment_path(@assignment,
                    redirect_params(attrs[:capability_stable_id], level_ordinal: level_ordinal)),
        status: :see_other, notice: "Comment posted."
    end
  rescue PersonDevelopment::Aggregate::CommandError => e
    comment_error(evidence_id, attrs&.[](:capability_stable_id), level_ordinal,
      "Could not post comment: #{e.message}")
  end

  # PATCH /assessments/:assessment_id/comments/:id
  def update
    comment = PersonDevelopmentComment.find(params.expect(:id))
    authorize comment, :update?, policy_class: PersonDevelopmentCommentPolicy

    attrs = params.expect(comment: [ :body ])

    if attrs[:body].to_s.strip.empty?
      redirect_back fallback_location: assessment_path(@assignment),
        alert: "Comment cannot be blank."
      return
    end

    PersonDevelopment::CommandHandler.new.edit_comment(
      @assignment.person_id, @assignment.framework_id, comment.id,
      body: attrs[:body].to_s,
      edited_by_id: current_person.id
    )

    if comment.evidence_id
      redirect_to comment_thread_path(comment), status: :see_other
    else
      redirect_to assessment_path(@assignment,
                    redirect_params(comment.capability_stable_id, level_ordinal: comment.level_ordinal)),
        status: :see_other, notice: "Comment updated."
    end
  rescue ActiveRecord::RecordNotFound
    head :not_found
  rescue PersonDevelopment::Aggregate::CommandError => e
    redirect_back fallback_location: assessment_path(@assignment),
      alert: "Could not update comment: #{e.message}"
  end

  # DELETE /assessments/:assessment_id/comments/:id
  def destroy
    comment = PersonDevelopmentComment.find(params.expect(:id))
    authorize comment, :destroy?, policy_class: PersonDevelopmentCommentPolicy

    reason = params.fetch(:comment, {}).permit(:reason)[:reason]
    PersonDevelopment::CommandHandler.new.delete_comment(
      @assignment.person_id, @assignment.framework_id, comment.id,
      deleted_by_id: current_person.id,
      reason: reason
    )

    if comment.evidence_id
      redirect_to comment_thread_path(comment), status: :see_other
    else
      redirect_to assessment_path(@assignment,
                    redirect_params(comment.capability_stable_id, level_ordinal: comment.level_ordinal)),
        status: :see_other, notice: "Comment deleted."
    end
  rescue ActiveRecord::RecordNotFound
    head :not_found
  rescue PersonDevelopment::Aggregate::CommandError => e
    redirect_back fallback_location: assessment_path(@assignment),
      alert: "Could not delete comment: #{e.message}"
  end

  private

  def require_person
    return if current_person

    # Rendering halts the before_action chain (Rails checks `performed?`), so
    # set_assignment won't run. Do NOT `throw :abort` — the around_action
    # `wrap_with_audit_metadata` (ApplicationController) wraps these callbacks,
    # and the throw escapes its `yield` uncaught, turning a 403 into a 500.
    head :forbidden
  end

  def set_assignment
    @assignment = PersonFrameworkAssignment.find(params.expect(:assessment_id))
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  # The linkage-thread frame's show URL — evidence-link responses land
  # here so the frame that hosted the form re-renders in place.
  def link_thread_path(evidence_id, capability_stable_id, level_ordinal, error: nil)
    assessment_evidence_link_thread_path(
      @assignment, evidence_id,
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal,
      error: error
    )
  end

  def comment_thread_path(comment)
    link_thread_path(comment.evidence_id, comment.capability_stable_id, comment.level_ordinal)
  end

  # Error surfacing differs by surface: the assessment page renders
  # flash alerts, but a flash is invisible inside the thread frame — the
  # frame's `error` param renders the message inline instead.
  def comment_error(evidence_id, capability_stable_id, level_ordinal, message)
    if evidence_id
      redirect_to link_thread_path(evidence_id, capability_stable_id, level_ordinal,
        error: message), status: :see_other
    else
      redirect_back fallback_location: assessment_path(@assignment), alert: message
    end
  end

  def redirect_params(capability_stable_id, level_ordinal: nil)
    opts = {}
    return opts unless capability_stable_id.present?

    opts[:capability] = capability_stable_id
    if (category_id = category_id_for(capability_stable_id))
      opts[:category] = category_id
    end
    opts[:level_ordinal] = level_ordinal if level_ordinal
    opts
  end

  def category_id_for(capability_stable_id)
    FrameworkState::Capability
      .joins(:category)
      .where(stable_id: capability_stable_id)
      .merge(FrameworkState::CapabilityCategory.where(framework_id: @assignment.framework_id))
      .pick(:category_id)
  end

  def user_not_authorized(_exception = nil)
    fallback = @assignment ? assessment_path(@assignment) : assessments_path
    redirect_back fallback_location: fallback,
      alert: "You are not authorized to perform this action."
  end
end
