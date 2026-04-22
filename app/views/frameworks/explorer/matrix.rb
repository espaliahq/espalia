# frozen_string_literal: true

# The capability × level matrix table.
#
# Renders a table with sticky column headers and category groups,
# each containing expandable capability rows with level cells.
#
class Views::Frameworks::Explorer::Matrix < Views::Base
  # @param matrix_data [Hash] output from MatrixDataBuilder
  # @param selected_role_ids [Array<String>]
  # @param framework_id [String] UUID of the framework (threaded to illustration inline editors)
  # @param mode [Symbol] :view or :edit
  def initialize(matrix_data:, selected_role_ids:, framework_id:, mode: :view, current_person_id: nil)
    @matrix_data = matrix_data
    @selected_role_ids = selected_role_ids
    @framework_id = framework_id
    @mode = mode
    @current_person_id = current_person_id
    @merged_levels = matrix_data[:merged_levels]
    @categories = matrix_data[:categories]
    # Prebuild role lookup so expanded cells don't hit AR once per bound
    # role per row — that was adding N+1 queries on edit-mode render.
    @roles_by_id = matrix_data[:selected_roles].index_by(&:role_id)
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
            selected_role_ids: @selected_role_ids,
            framework_id: @framework_id,
            mode: @mode,
            roles_by_id: @roles_by_id,
            current_person_id: @current_person_id
          )
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
