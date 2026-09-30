# frozen_string_literal: true

# What the three alignment-milestone controllers share: the assignment, the
# lens the milestone is against (`as_role` / `as_level`, as the page reads
# them), a dispatch through the milestone's Operation, and a redirect back
# to the page read through that lens (ADR-22).
module Assessments::AlignmentMilestone
  extend ActiveSupport::Concern

  included do
    before_action :require_person
    before_action :set_assignment
  end

  private

  # @param operation [Class<Operations::Base>]
  # @return [Hash] the Operation's result
  def dispatch_milestone(operation)
    operation.call(
      context: pundit_user,
      params: { assignment_id: @assignment.id, as_role_id: params[:as_role].presence,
                as_level_ordinal: params[:as_level].presence&.to_i }.compact
    )
  end

  def lens_assessment_path
    assessment_path(@assignment, { as_role: params[:as_role].presence, as_level: params[:as_level].presence }.compact)
  end

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
