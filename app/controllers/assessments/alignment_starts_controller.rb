# frozen_string_literal: true

# Formally opens alignment against a role for the current cycle of an
# assessment (ADR-22) — the home role, or the lens role named by `as_role` /
# `as_level` ("Start alignment against PM3").
#
# Once started, the manager's ratings on the role's cells are disclosed to
# the assessee and self/manager ratings on them freeze (enforced by the
# rating Operations and the aggregate). Only the assessee's reporting
# manager can call this — see {AssessmentPolicy#start_alignment?}, checked
# by {Operations::Assessments::StartAlignment}.
#
class Assessments::AlignmentStartsController < ApplicationController
  include Assessments::AlignmentMilestone

  # POST /assessments/:assessment_id/alignment_start
  def create
    authorize @assignment, :show?

    result = dispatch_milestone(Operations::Assessments::StartAlignment)
    notice = if result[:home]
      "Alignment started — self and manager ratings on #{result[:role_code]}#{result[:level_ordinal]}'s " \
        "capabilities are now locked."
    else
      "Alignment against #{result[:role_code]}#{result[:level_ordinal]} started — " \
        "your ratings on its capabilities are now shared and locked."
    end
    redirect_to lens_assessment_path, notice: notice
  rescue Operations::Base::ParameterError, RuntimeError => e
    redirect_to lens_assessment_path, alert: e.message
  end
end
