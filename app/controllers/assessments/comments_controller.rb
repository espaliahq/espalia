# frozen_string_literal: true

# Posts, edits, and soft-deletes comments on a person's assessment.
#
# V1 supports only `commentable_type: "assessment_cell"` (anchored to
# a capability_stable_id × level_ordinal coordinate). Future
# commentable types (growth plans, focus areas, check-ins) will reuse
# this controller with a different `commentable_type` and shape.
#
class Assessments::CommentsController < ApplicationController
  before_action :require_person
  before_action :set_assignment

  # POST /assessments/:assessment_id/comments
  def create
    authorize @assignment, :create?, policy_class: PersonDevelopmentCommentPolicy

    attrs = params.expect(comment: [
      :capability_stable_id, :level_ordinal, :body, :parent_id
    ])

    level_ordinal = Integer(attrs[:level_ordinal], exception: false)
    unless level_ordinal &&
        FrameworkState::Level.exists?(role_id: @assignment.role_id, ordinal: level_ordinal)
      head :unprocessable_content
      return
    end

    if attrs[:body].to_s.strip.empty?
      redirect_back fallback_location: assessment_path(@assignment),
        alert: "Comment cannot be blank."
      return
    end

    comment_id = SecureRandom.uuid_v7
    PersonDevelopment::CommandHandler.new.post_comment(
      @assignment.person_id, @assignment.framework_id, comment_id,
      commentable_type: PersonDevelopmentComment::ASSESSMENT_CELL,
      capability_stable_id: attrs[:capability_stable_id],
      level_ordinal: level_ordinal,
      body: attrs[:body].to_s,
      author_id: current_person.id,
      parent_id: attrs[:parent_id].presence
    )

    redirect_to assessment_path(@assignment,
                  redirect_params(attrs[:capability_stable_id], level_ordinal: level_ordinal)),
      status: :see_other, notice: "Comment posted."
  rescue PersonDevelopment::Aggregate::CommandError => e
    redirect_back fallback_location: assessment_path(@assignment),
      alert: "Could not post comment: #{e.message}"
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

    redirect_to assessment_path(@assignment,
                  redirect_params(comment.capability_stable_id, level_ordinal: comment.level_ordinal)),
      status: :see_other, notice: "Comment updated."
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

    redirect_to assessment_path(@assignment,
                  redirect_params(comment.capability_stable_id, level_ordinal: comment.level_ordinal)),
      status: :see_other, notice: "Comment deleted."
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
