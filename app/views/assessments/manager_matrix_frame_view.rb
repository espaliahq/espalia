# frozen_string_literal: true

# Turbo Frame wrapper for the manager assessment matrix.
# Rendered by AssessmentsController#matrix for frame-only refreshes.
#
class Views::Assessments::ManagerMatrixFrameView < Views::Base
  def initialize(framework:, matrix_data:)
    @framework = framework
    @matrix_data = matrix_data
  end

  def view_template
    turbo_frame_tag("assessment-matrix") do
      render Views::Assessments::ManagerMatrix.new(
        matrix_data: @matrix_data,
        framework_id: @framework.framework_id
      )
    end
  end
end
