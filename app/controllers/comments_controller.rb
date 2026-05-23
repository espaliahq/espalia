# frozen_string_literal: true

# Individually-addressable comments — `GET /comments/:id` redirects
# to the assessment view (for assessment-cell comments) with the cell
# focused. Future commentable types (growth plans, focus areas) will
# add their own branches here.
#
# Keeping comments addressable by id is a domain requirement: evidence
# may link to a comment to elevate it as evidence of a behaviour, and
# external systems (notifications, deep links) should be able to point
# directly at one.
#
class CommentsController < ApplicationController
  before_action :require_person

  # GET /comments/:id
  def show
    comment = PersonDevelopmentComment.find(params.expect(:id))
    authorize comment, :show?, policy_class: PersonDevelopmentCommentPolicy

    case comment.commentable_type
    when PersonDevelopmentComment::ASSESSMENT_CELL
      redirect_to_assessment(comment)
    else
      head :not_found
    end
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  private

  def require_person
    return if current_person

    redirect_to root_path, alert: "No person profile linked to your account."
  end

  def redirect_to_assessment(comment)
    assignment = PersonFrameworkAssignment.find_by(
      person_id: comment.person_id, framework_id: comment.framework_id
    )
    if assignment.nil?
      head :not_found
      return
    end

    category_id = FrameworkState::Capability
      .joins(:category)
      .where(stable_id: comment.capability_stable_id)
      .merge(FrameworkState::CapabilityCategory.where(framework_id: comment.framework_id))
      .pick(:category_id)

    opts = {
      capability: comment.capability_stable_id,
      level_ordinal: comment.level_ordinal
    }
    opts[:category] = category_id if category_id
    redirect_to assessment_path(assignment, opts), allow_other_host: false
  end

  def user_not_authorized(_exception = nil)
    redirect_to root_path, alert: "You are not authorized to view that comment."
  end
end
