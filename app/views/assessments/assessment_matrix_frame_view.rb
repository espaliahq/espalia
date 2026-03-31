# frozen_string_literal: true

# Turbo Frame wrapper for the unified assessment matrix.
# Rendered by AssessmentsController#matrix for frame-only refreshes.
#
class Views::Assessments::AssessmentMatrixFrameView < Views::Base
  # @param framework [FrameworkState::Framework]
  # @param matrix_data [Hash]
  # @param assignment [PersonFrameworkAssignment]
  # @param context [Symbol] :self, :manager, or :alignment
  def initialize(framework:, matrix_data:, assignment:, context: :self)
    @framework = framework
    @matrix_data = matrix_data
    @assignment = assignment
    @context = context
  end

  def view_template
    turbo_frame_tag("assessment-matrix") do
      render Views::Assessments::AssessmentMatrix.new(
        matrix_data: @matrix_data,
        assessment_id: @assignment.id,
        context: @context
      )
    end
  end
end
