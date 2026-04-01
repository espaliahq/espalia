# frozen_string_literal: true

# Turbo Frame wrapper for the unified assessment matrix.
# Rendered by AssessmentsController#matrix for frame-only refreshes.
#
class Views::Assessments::AssessmentMatrixFrameView < Views::Base
  # @param framework [FrameworkState::Framework]
  # @param matrix_data [Hash]
  # @param assignment [PersonFrameworkAssignment]
  # @param context [Symbol] :self, :manager, or :alignment
  # @param active_category_id [String, nil] active tab category ID
  # @param expanded_capability_id [String, nil] pre-expanded capability stable_id
  def initialize(framework:, matrix_data:, assignment:, context: :self,
                 active_category_id: nil, expanded_capability_id: nil)
    @framework = framework
    @matrix_data = matrix_data
    @assignment = assignment
    @context = context
    @active_category_id = active_category_id
    @expanded_capability_id = expanded_capability_id
  end

  def view_template
    turbo_frame_tag("assessment-matrix") do
      render Views::Assessments::AssessmentMatrix.new(
        matrix_data: @matrix_data,
        assessment_id: @assignment.id,
        context: @context,
        active_category_id: @active_category_id,
        expanded_capability_id: @expanded_capability_id
      )
    end
  end
end
