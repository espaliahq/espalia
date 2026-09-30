# frozen_string_literal: true

# Marks alignment against a role complete for the current cycle of an
# assessment (ADR-22) — the home role, or the lens role named by `as_role`.
#
# Only the assessee's reporting manager can call this — see
# {AssessmentPolicy#complete_alignment?}. Completion is gated per role on
# full current-level aligned coverage of that role's cells, in two layers
# inside {Operations::Assessments::CompleteAlignment}: the read-model count
# gives the friendly redirect, and the counted cells go into the aggregate,
# which re-checks them atomically against the stream.
#
class Assessments::AlignmentCompletionsController < ApplicationController
  include Assessments::AlignmentMilestone

  # POST /assessments/:assessment_id/alignment_completion
  def create
    authorize @assignment, :show?

    result = dispatch_milestone(Operations::Assessments::CompleteAlignment)
    notice = if result[:home]
      "Alignment complete — the agreed ratings on #{result[:role_code]}#{result[:level_ordinal]}'s " \
        "capabilities are now locked."
    else
      "Alignment against #{result[:role_code]}#{result[:level_ordinal]} complete."
    end
    redirect_to lens_assessment_path, notice: notice
  rescue Operations::Base::ParameterError => e
    redirect_to lens_assessment_path, alert: e.message
  rescue RuntimeError => e
    Rails.logger.error("[AlignmentCompletions] #{e.class}: #{e.message}")
    redirect_to lens_assessment_path, alert: "Could not mark alignment complete."
  end
end
