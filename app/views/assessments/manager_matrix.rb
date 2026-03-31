# frozen_string_literal: true

# Manager assessment capability matrix table.
# Uses {ManagerMatrixCategoryGroup} with dual-frequency cells.
#
class Views::Assessments::ManagerMatrix < Views::Base
  # @param matrix_data [Hash] from Assessments::MatrixDataBuilder
  # @param framework_id [String] UUID
  def initialize(matrix_data:, framework_id:)
    @matrix_data = matrix_data
    @framework_id = framework_id
  end

  def view_template
    table(class: "w-full border-collapse", data: { controller: "matrix" }) do
      render Views::Assessments::MatrixHeader.new(
        merged_levels: @matrix_data[:merged_levels],
        person_level: @matrix_data[:person_level],
        inferred_level: @matrix_data[:inferred_level]
      )
      tbody do
        @matrix_data[:categories].each do |cat_data|
          render Views::Assessments::ManagerMatrixCategoryGroup.new(
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
