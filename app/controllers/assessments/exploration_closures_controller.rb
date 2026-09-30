# frozen_string_literal: true

# Closes a declared exploration (ADR-22) with its outcome — "Stop exploring"
# on the lens banner. Dispatches the shared
# {Operations::Assessments::CloseExploration} and returns to the lens.
class Assessments::ExplorationClosuresController < ApplicationController
  include Assessments::ExplorationActions

  # POST /assessments/:assessment_id/explorations/:exploration_id/closure
  def create
    authorize @assignment, :close_exploration?

    result = Operations::Assessments::CloseExploration.call(
      context: pundit_user,
      params: { assignment_id: @assignment.id, exploration_id: params.expect(:exploration_id),
                outcome: params[:outcome].to_s, note: params[:note] }.compact
    )
    redirect_to lens_assessment_path,
      notice: "Stopped exploring #{result.dig(:target, :role_name)} · #{result.dig(:target, :code)}."
  rescue Operations::Base::ParameterError => e
    redirect_to lens_assessment_path, alert: e.message
  rescue ActiveRecord::RecordNotFound
    redirect_to lens_assessment_path, alert: "That exploration is no longer open."
  end
end
