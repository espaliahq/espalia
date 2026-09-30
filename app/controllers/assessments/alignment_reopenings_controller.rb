# frozen_string_literal: true

# Re-opens a completed alignment against a role for the current cycle of an
# assessment (ADR-22), returning it to the `aligning` phase so the manager
# can correct a completion made by accident. Agreed values are preserved.
#
# Only the assessee's reporting manager can call this, and only while the
# cycle is still open — see {AssessmentPolicy#reopen_alignment?}. Dispatches
# through {Operations::Assessments::ReopenAlignment} so web and MCP behave
# identically.
#
class Assessments::AlignmentReopeningsController < ApplicationController
  include Assessments::AlignmentMilestone

  # POST /assessments/:assessment_id/alignment_reopening
  def create
    authorize @assignment, :show?

    dispatch_milestone(Operations::Assessments::ReopenAlignment)
    redirect_to lens_assessment_path,
      notice: "Alignment re-opened — agreed ratings are kept; mark complete again when ready."
  rescue Operations::Base::ParameterError, PersonDevelopment::Aggregate::CommandError, RuntimeError => e
    Rails.logger.error("[AlignmentReopenings] #{e.class}: #{e.message}")
    redirect_to lens_assessment_path, alert: "Could not re-open alignment."
  end
end
