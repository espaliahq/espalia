# frozen_string_literal: true

# Turbo Frame wrapper for the assessment hero summary.
# Rendered by AssessmentsController#scoring for frame-only refreshes.
#
# Now renders HeroSummary (the sticky hero card that replaced the old sidebar).
#
class Views::Assessments::ScoringPanelFrameView < Views::Base
  # @param matrix_data [Hash] output from Assessments::MatrixDataBuilder
  # @param context [Symbol] :self, :manager, or :alignment
  # @param active_category_id [String, nil]
  # @param assessment_id [String, nil] UUID
  def initialize(matrix_data:, context: :self, active_category_id: nil, assessment_id: nil)
    @matrix_data = matrix_data
    @context = context
    @active_category_id = active_category_id
    @assessment_id = assessment_id
  end

  def view_template
    turbo_frame_tag("assessment-scoring") do
      render Views::Assessments::HeroSummary.new(
        scoring: @matrix_data[:scoring],
        self_scoring: @matrix_data[:self_scoring],
        manager_scoring: @matrix_data[:manager_scoring],
        aligned_scoring: @matrix_data[:aligned_scoring],
        categories: @matrix_data[:categories],
        person_level: @matrix_data[:person_level],
        merged_levels: @matrix_data[:merged_levels],
        mastery_threshold: @matrix_data[:mastery_threshold],
        meeting_expectation_threshold: @matrix_data[:meeting_expectation_threshold],
        assessment_id: @assessment_id,
        context: @context
      )
    end
  end
end
