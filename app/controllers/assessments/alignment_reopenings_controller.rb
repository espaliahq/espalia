# frozen_string_literal: true

# Re-opens a completed alignment for the current cycle of an assessment,
# returning it to the `aligning` phase so the manager can correct a
# completion made by accident. Agreed values are preserved.
#
# Only the assessee's current direct manager can call this, and only while
# the cycle is still open — see {AssessmentPolicy#reopen_alignment?}. Dispatches
# through {Operations::Assessments::ReopenAlignment} so web and MCP behave
# identically.
#
class Assessments::AlignmentReopeningsController < ApplicationController
  before_action :require_person
  before_action :set_assignment

  # POST /assessments/:assessment_id/alignment_reopening
  def create
    authorize @assignment, :reopen_alignment?

    Operations::Assessments::ReopenAlignment.call(
      context: pundit_user,
      params: { assignment_id: @assignment.id }
    )

    redirect_to assessment_path(@assignment),
      notice: "Alignment re-opened — agreed ratings are kept; mark complete again when ready."
  rescue Operations::Base::ParameterError, PersonDevelopment::Aggregate::CommandError => e
    Rails.logger.error("[AlignmentReopenings] #{e.class}: #{e.message}")
    redirect_to assessment_path(@assignment), alert: "Could not re-open alignment."
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
