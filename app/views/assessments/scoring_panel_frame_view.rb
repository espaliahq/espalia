# frozen_string_literal: true

# Turbo Frame wrapper for the scoring panel sidebar.
# Rendered by AssessmentsController#scoring for frame-only refreshes.
#
class Views::Assessments::ScoringPanelFrameView < Views::Base
  # @param matrix_data [Hash] output from Assessments::MatrixDataBuilder
  # @param context [Symbol] :self, :manager, or :alignment
  def initialize(matrix_data:, context: :self)
    @matrix_data = matrix_data
    @context = context
  end

  def view_template
    turbo_frame_tag("assessment-scoring") do
      render Views::Assessments::ScoringPanel.new(
        scoring: @matrix_data[:scoring],
        self_scoring: @matrix_data[:self_scoring],
        manager_scoring: @matrix_data[:manager_scoring],
        aligned_scoring: @matrix_data[:aligned_scoring],
        categories: @matrix_data[:categories],
        person_level: @matrix_data[:person_level],
        mastery_threshold: @matrix_data[:mastery_threshold],
        meeting_expectation_threshold: @matrix_data[:meeting_expectation_threshold],
        context: @context
      )
    end
  end
end
