# frozen_string_literal: true

# Assessment capability matrix table.
# Single-role variant — no role tree, capabilities filtered to assigned role.
#
class Views::Assessments::Matrix < Views::Base
  # @param matrix_data [Hash] from Assessments::MatrixDataBuilder
  # @param framework_id [String] UUID
  def initialize(matrix_data:, framework_id:)
    @matrix_data = matrix_data
    @framework_id = framework_id
  end

  def view_template
    table(class: "w-full border-collapse") do
      render Views::Assessments::MatrixHeader.new(
        merged_levels: @matrix_data[:merged_levels],
        person_level: @matrix_data[:person_level],
        meeting_expectation_threshold: @matrix_data[:meeting_expectation_threshold],
        mastery_threshold: @matrix_data[:mastery_threshold]
      )
      tbody do
        @matrix_data[:categories].each do |cat_data|
          render Views::Assessments::MatrixCategoryGroup.new(
            category_data: cat_data,
            merged_levels: @matrix_data[:merged_levels],
            person_level: @matrix_data[:person_level],
            scoring: @matrix_data[:scoring],
            framework_id: @framework_id
          )
        end
      end
    end
  end
end
