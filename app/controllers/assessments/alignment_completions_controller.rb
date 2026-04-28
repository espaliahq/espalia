# frozen_string_literal: true

# Marks alignment complete for the current cycle of an assessment.
#
# After this lands, ALL ratings (including aligned values) are frozen for
# the cycle. Only the assessee's current direct manager can call this — see
# {AssessmentPolicy#complete_alignment?}.
#
class Assessments::AlignmentCompletionsController < ApplicationController
  before_action :require_person
  before_action :set_assignment

  # POST /assessments/:assessment_id/alignment_completion
  def create
    authorize @assignment, :complete_alignment?

    cycle = @assignment.current_open_cycle
    unless cycle
      redirect_to assessment_path(@assignment), alert: "No open assessment cycle."
      return
    end

    PersonDevelopment::CommandHandler.new.complete_alignment(
      @assignment.person_id, @assignment.framework_id, cycle.cycle_id,
      completed_by_id: current_person.id
    )

    redirect_to assessment_path(@assignment),
      notice: "Alignment complete — all ratings for this cycle are now locked."
  rescue RuntimeError => e
    Rails.logger.error("[AlignmentCompletions] #{e.class}: #{e.message}")
    redirect_to assessment_path(@assignment),
      alert: "Could not mark alignment complete."
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
