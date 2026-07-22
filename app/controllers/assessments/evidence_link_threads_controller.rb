# frozen_string_literal: true

# Serves one evidence linkage's discussion thread into the lazy
# turbo-frame inside the evidence card (see
# {Views::Assessments::Evidence::LinkThreadFrame}).
#
# Posting / editing / deleting the thread's comments goes through
# {Assessments::CommentsController} (same endpoints as cell comments —
# the `comment[evidence_id]` param selects the evidence_link type),
# which redirects back here so the frame re-renders in place.
#
class Assessments::EvidenceLinkThreadsController < ApplicationController
  before_action :require_person
  before_action :set_assignment

  # GET /assessments/:assessment_id/evidence/:evidence_id/link_thread
  def show
    # Thread visibility follows comment visibility (assessee + manager
    # chain + active delegate + tenant admin) — deliberately NOT the
    # evidence author's hub visibility: a peer who provided the feedback
    # is not part of the assessment-side discussion (see assessments.md).
    authorize @assignment, :index?, policy_class: PersonDevelopmentCommentPolicy

    # Scoping the lookup by the authorized assignment's person+framework
    # prevents reading another person's evidence via a forged id.
    item = EvidenceItem
      .for_person(@assignment.person_id)
      .for_framework(@assignment.framework_id)
      .find(params.expect(:evidence_id))

    capability_stable_id = params.expect(:capability_stable_id)
    level_ordinal = Integer(params.expect(:level_ordinal), exception: false)
    if level_ordinal.nil?
      head :unprocessable_content
      return
    end

    query = Assessments::EvidenceLinkThreadQuery.new(
      item: item,
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal
    )

    render Views::Assessments::Evidence::LinkThreadFrame.new(
      item: item,
      assessment_id: @assignment.id,
      capability_stable_id: capability_stable_id,
      level_ordinal: level_ordinal,
      comments: query.comments,
      lifecycle: query.lifecycle_entries,
      link: query.link,
      viewer_person_id: current_person.id,
      can_comment: PersonDevelopmentCommentPolicy.new(pundit_user, @assignment).create?,
      tenant_admin: current_user&.global_admin? || current_tenant_user&.admin? || false,
      error: params[:error].presence
    )
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  private

  def require_person
    return if current_person

    head :forbidden
  end

  def set_assignment
    @assignment = PersonFrameworkAssignment.find(params.expect(:assessment_id))
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end
end
