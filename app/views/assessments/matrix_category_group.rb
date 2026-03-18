# frozen_string_literal: true

# Category header + child capability rows in the assessment matrix.
# Shows category tolerance indicator and pass/fail status from scoring.
#
class Views::Assessments::MatrixCategoryGroup < Views::Base
  # @param category_data [Hash] from MatrixDataBuilder
  # @param merged_levels [Array<Hash>]
  # @param person_level [Integer]
  # @param scoring [Hash] scoring output
  # @param framework_id [String]
  def initialize(category_data:, merged_levels:, person_level:, scoring:, framework_id:)
    @category_data = category_data
    @category = category_data[:category]
    @merged_levels = merged_levels
    @person_level = person_level
    @scoring = scoring
    @framework_id = framework_id
  end

  def view_template
    # Category header row
    tr(class: "sticky top-[41px] z-[5]") do
      td(
        colspan: @merged_levels.size + 1,
        class: "px-4 py-2 bg-gray-100 dark:bg-gray-800 border-b " \
               "border-gray-200 dark:border-gray-700"
      ) do
        div(class: "flex items-center justify-between") do
          div(class: "flex items-center gap-2") do
            span(class: "text-sm font-semibold text-gray-900 dark:text-white") { @category.name }
            render Components::Kit::CategoryToleranceIndicator.new(
              tolerance: @category_data[:category_tolerance]
            )
          end

          render Views::Assessments::CategoryStatus.new(
            category_id: @category.category_id,
            category_result: @scoring[:category_results][@category.category_id]
          )
        end
      end
    end

    # Capability rows
    @category_data[:capabilities].each do |cap_data|
      render Views::Assessments::MatrixRow.new(
        capability_data: cap_data,
        merged_levels: @merged_levels,
        person_level: @person_level,
        framework_id: @framework_id
      )
    end
  end
end
