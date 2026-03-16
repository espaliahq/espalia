# frozen_string_literal: true

# The capability × level matrix table.
#
# Renders a table with sticky column headers and category groups,
# each containing expandable capability rows with level cells.
#
class Views::Frameworks::Explorer::Matrix < Views::Base
  # @param matrix_data [Hash] output from MatrixDataBuilder
  # @param selected_role_ids [Array<String>]
  def initialize(matrix_data:, selected_role_ids:)
    @matrix_data = matrix_data
    @selected_role_ids = selected_role_ids
    @merged_levels = matrix_data[:merged_levels]
    @categories = matrix_data[:categories]
  end

  def view_template
    if @merged_levels.empty?
      empty_state
    else
      matrix_table
    end
  end

  private

  def matrix_table
    div(class: "overflow-x-auto") do
      table(class: "w-full border-collapse") do
        render Views::Frameworks::Explorer::MatrixHeader.new(
          merged_levels: @merged_levels,
          selected_role_count: @matrix_data[:selected_roles].size
        )
        tbody do
          @categories.each do |cat_data|
            render Views::Frameworks::Explorer::MatrixCategoryGroup.new(
              category_data: cat_data,
              merged_levels: @merged_levels,
              selected_role_ids: @selected_role_ids
            )
          end
        end
      end
    end
  end

  def empty_state
    div(class: "flex items-center justify-center h-64") do
      div(class: "text-center") do
        p(class: "text-gray-500 dark:text-gray-400 text-sm") do
          "Select roles from the tree to view the capability matrix."
        end
      end
    end
  end
end
