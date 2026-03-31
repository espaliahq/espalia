# frozen_string_literal: true

# Turbo Frame wrapper for the unified assessment matrix.
# Rendered by AssessmentsController#matrix for frame-only refreshes.
#
class Views::Assessments::AssessmentMatrixFrameView < Views::Base
  # @param framework [FrameworkState::Framework]
  # @param matrix_data [Hash]
  # @param context [Symbol] :self, :manager, or :alignment
  def initialize(framework:, matrix_data:, context: :self)
    @framework = framework
    @matrix_data = matrix_data
    @context = context
  end

  def view_template
    turbo_frame_tag("assessment-matrix") do
      render Views::Assessments::AssessmentMatrix.new(
        matrix_data: @matrix_data,
        framework_id: @framework.framework_id,
        context: @context
      )
    end
  end
end
