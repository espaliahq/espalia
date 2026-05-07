# frozen_string_literal: true

# Formally opens alignment for the current cycle of an assessment.
#
# Once started, individual self/manager ratings are frozen for the cycle
# (enforced by both the {AssessmentPolicy} freeze checks and the aggregate
# guards). Only the assessee's current direct manager can call this — see
# {AssessmentPolicy#start_alignment?}.
#
class Assessments::AlignmentStartsController < ApplicationController
  before_action :require_person
  before_action :set_assignment

  # POST /assessments/:assessment_id/alignment_start
  def create
    authorize @assignment, :start_alignment?

    cycle = @assignment.current_open_cycle
    unless cycle
      redirect_to assessment_path(@assignment), alert: "No open assessment cycle."
      return
    end

    PersonDevelopment::CommandHandler.new.start_alignment(
      @assignment.person_id, @assignment.framework_id, cycle.cycle_id,
      started_by_id: current_person.id
    )

    redirect_to assessment_path(@assignment),
      notice: "Alignment started — self and manager ratings are now locked for this cycle."
  rescue RuntimeError => e
    redirect_to assessment_path(@assignment), alert: e.message
  end

  private

  def require_person
    head :forbidden unless current_person
  end

  def set_assignment
    return unless current_person

    @assignment = PersonFrameworkAssignment.find(params.expect(:assessment_id))
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  def user_not_authorized(_exception = nil)
    head :forbidden
  end
end
