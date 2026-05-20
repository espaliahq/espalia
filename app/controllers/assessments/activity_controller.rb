# frozen_string_literal: true

# Renders the activity feed Turbo Frame for an assessment.
#
# Lives at GET /assessments/:id/activity. The frame is reloaded by the
# `assessment_sync_controller` whenever the `assessment_updates`
# ActionCable channel fires (rating change, evidence added/withdrawn,
# alignment milestone) so the right-hand sidebar stays in sync without
# a page refresh.
#
class Assessments::ActivityController < ApplicationController
  before_action :require_person
  before_action :set_assignment

  # GET /assessments/:assessment_id/activity
  def show
    authorize @assignment, :show?, policy_class: AssessmentPolicy

    entries = Assessments::ActivityFeedQuery.new(
      assignment: @assignment,
      context: assessment_context,
      viewer_person_id: current_person&.id,
      viewer_sees_all: viewer_sees_all_evidence?,
      alignment_started: alignment_started?
    ).call

    render Views::Assessments::Activity::FeedFrameView.new(
      entries: entries,
      assignment: @assignment
    ), layout: false
  end

  private

  def require_person
    return if current_person

    # `throw :abort` halts the before_action chain so subsequent callbacks
    # (e.g. set_assignment) don't run and risk a DoubleRenderError.
    head :forbidden
    throw :abort
  end

  def set_assignment
    @assignment = PersonFrameworkAssignment.find(params.expect(:assessment_id))
  rescue ActiveRecord::RecordNotFound
    head :not_found
    throw :abort
  end

  def assessment_context
    if @assignment.person_id != current_person.id
      :manager
    else
      :self
    end
  end

  def viewer_sees_all_evidence?
    return false unless current_person
    return true if current_user&.global_admin? || current_tenant_user&.admin?
    return true if @assignment.person_id == current_person.id

    Person.find_by(id: @assignment.person_id)&.managed_by?(current_person) || false
  end

  def alignment_started?
    %w[aligning aligned].include?(@assignment.current_open_cycle_participation&.status)
  end

  def user_not_authorized(_exception = nil)
    redirect_back fallback_location: assessments_path,
      alert: "You are not authorized to perform this action."
  end
end
