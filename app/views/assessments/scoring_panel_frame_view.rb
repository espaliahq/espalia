# frozen_string_literal: true

# Turbo Frame wrapper for the scoring panel sidebar.
# Rendered by AssessmentsController#scoring for frame-only refreshes.
#
class Views::Assessments::ScoringPanelFrameView < Views::Base
  # @param matrix_data [Hash] output from Assessments::MatrixDataBuilder
  # @param context [Symbol] :self, :manager, or :alignment
  # @param active_category_id [String, nil] currently selected category tab
  # @param assessment_id [String, nil] UUID for building matrix URL links
  def initialize(matrix_data:, context: :self, active_category_id: nil, assessment_id: nil)
    @matrix_data = matrix_data
    @context = context
    @active_category_id = active_category_id
    @assessment_id = assessment_id
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
        active_category_id: @active_category_id,
        assessment_id: @assessment_id,
        context: @context
      )
    end
  end
end
