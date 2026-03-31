# frozen_string_literal: true

# Turbo Frame wrapper for the scoring panel sidebar.
# Rendered by AssessmentsController#scoring for frame-only refreshes.
#
class Views::Assessments::ScoringPanelFrameView < Views::Base
  # @param matrix_data [Hash] output from Assessments::MatrixDataBuilder
  def initialize(matrix_data:)
    @matrix_data = matrix_data
  end

  def view_template
    turbo_frame_tag("assessment-scoring") do
      render Views::Assessments::ScoringPanel.new(
        scoring: @matrix_data[:scoring],
        categories: @matrix_data[:categories],
        person_level: @matrix_data[:person_level],
        mastery_threshold: @matrix_data[:mastery_threshold],
        meeting_expectation_threshold: @matrix_data[:meeting_expectation_threshold]
      )
    end
  end
end
