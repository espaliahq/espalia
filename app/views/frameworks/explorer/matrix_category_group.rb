# frozen_string_literal: true

# Collapsible category group within the matrix.
#
# Renders a sticky category header row spanning all columns,
# followed by capability rows for this category.
#
class Views::Frameworks::Explorer::MatrixCategoryGroup < Views::Base
  include Views::Frameworks::Explorer::Concerns::SuggestionDecoration

  # @param category_data [Hash] from MatrixDataBuilder: { category:, capabilities: [...] }
  # @param merged_levels [Array<Hash>]
  # @param selected_role_ids [Array<String>]
  # @param framework_id [String] UUID of the framework (threaded to illustration inline editors)
  # @param mode [Symbol] :view or :edit
  def initialize(category_data:, merged_levels:, selected_role_ids:, framework_id:, mode: :view)
    @category = category_data[:category]
    @capabilities = category_data[:capabilities]
    @category_pending_count = category_data[:pending_suggestion_count] || 0
    @merged_levels = merged_levels
    @selected_role_ids = selected_role_ids
    @framework_id = framework_id
    @mode = mode
  end

  def view_template
    category_header
    capability_rows
  end

  private

  def category_header
    col_count = @merged_levels.size + 1 # +1 for capability name column

    tr(
      class: "sticky top-[41px] z-[5]",
      data: {
        matrix_target: "categoryHeader",
        category_id: @category.category_id
      }
    ) do
      td(
        colspan: col_count,
        class: "px-4 py-2 bg-gray-100 dark:bg-gray-800 border-b border-gray-200 dark:border-gray-700"
      ) do
        div(class: "flex items-center gap-2") do
          # Chevron collapses/expands the category rows
          button(
            type: "button",
            class: "flex items-center justify-center w-4 h-4 cursor-pointer rounded " \
                   "hover:bg-gray-200 dark:hover:bg-gray-700",
            data: {
              action: "click->matrix#toggleCategory",
              category_id: @category.category_id
            },
            aria_label: "Toggle category"
          ) do
            svg(
              class: "w-3 h-3 text-gray-400 rotate-90 transition-transform",
              data: { matrix_target: "categoryChevron" },
              fill: "none", viewBox: "0 0 24 24", stroke: "currentColor", stroke_width: "2"
            ) do |s|
              s.path(d: "M9 5l7 7-7 7")
            end
          end

          # Category name + count are the focus hit target
          span(
            class: "flex items-center gap-2 cursor-pointer hover:underline",
            data: {
              action: "click->matrix#focusCategory",
              category_id: @category.category_id
            }
          ) do
            render Views::Frameworks::Explorer::CategoryNameFrame.new(
              category: @category,
              framework_id: @framework_id,
              mode: @mode,
              pending_edit_count: @category_pending_count
            )

            span(class: "text-xs text-gray-400 dark:text-gray-500") do
              "#{@capabilities.size} #{'capability'.pluralize(@capabilities.size)}"
            end
          end
        end
      end
    end
  end

  def capability_rows
    @capabilities.each do |cap_data|
      render Views::Frameworks::Explorer::MatrixRow.new(
        capability_data: cap_data,
        merged_levels: @merged_levels,
        selected_role_ids: @selected_role_ids,
        framework_id: @framework_id,
        mode: @mode
      )
    end
  end
end
