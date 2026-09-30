# frozen_string_literal: true

# Declares an exploration of the role and level the page is read through
# (ADR-22) — "Keep exploring this" from the assessee, "Share with Alex" from
# the manager or a rating delegate. Dispatches the shared
# {Operations::Assessments::StartExploration}, so the web and MCP apply the
# same rules, and returns to the lens.
class Assessments::ExplorationsController < ApplicationController
  include Assessments::ExplorationActions

  # POST /assessments/:assessment_id/explorations
  def create
    authorize @assignment, :start_exploration?

    result = Operations::Assessments::StartExploration.call(
      context: pundit_user,
      params: { assignment_id: @assignment.id, as_role_id: params[:as_role].presence,
                as_level_ordinal: params[:as_level].presence&.to_i, note: params[:note] }.compact
    )
    label = "#{result.dig(:target, :role_name)} · #{result.dig(:target, :code)}"
    redirect_to lens_assessment_path, notice: "You're exploring #{label} — #{other_party_name} can see it now."
  rescue Operations::Base::ParameterError => e
    redirect_to lens_assessment_path, alert: e.message
  end
end
