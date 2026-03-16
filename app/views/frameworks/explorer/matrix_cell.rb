# frozen_string_literal: true

# Single cell in the capability × level matrix.
#
# Shows the behavioural expectation text and an illustration indicator.
# When the row is expanded, the cell's hidden detail content is revealed
# by the matrix Stimulus controller.
#
class Views::Frameworks::Explorer::MatrixCell < Views::Base
  # @param cell_data [Hash, nil] from MatrixDataBuilder — nil for empty cells
  # @param ordinal [Integer] the level ordinal for this column
  def initialize(cell_data:, ordinal:)
    @cell_data = cell_data
    @ordinal = ordinal
  end

  def view_template
    if @cell_data.nil?
      empty_cell
    else
      filled_cell
    end
  end

  private

  def empty_cell
    td(class: "px-3 py-2.5 text-center border-b border-r border-gray-100 dark:border-gray-800 " \
              "bg-gray-50/50 dark:bg-gray-800/20 align-top") do
      span(class: "text-gray-300 dark:text-gray-600") { "\u2014" }
    end
  end

  def filled_cell
    td(
      class: "px-3 py-2.5 border-b border-r border-gray-100 dark:border-gray-800 align-top " \
             "cursor-pointer hover:bg-blue-50/50 dark:hover:bg-blue-900/10 transition-colors",
      data: { action: "click->matrix#toggleCell", ordinal: @ordinal }
    ) do
      expectation_text
      illustration_indicator if @cell_data[:illustration_count] > 0
      cell_detail
    end
  end

  def expectation_text
    p(class: "text-sm text-gray-700 dark:text-gray-300 line-clamp-3") do
      @cell_data[:expectation].description
    end
  end

  def illustration_indicator
    div(class: "mt-1.5 flex items-center gap-1") do
      span(class: "w-1.5 h-1.5 rounded-full bg-primary") { }
      span(class: "text-[10px] text-gray-400 dark:text-gray-500") do
        count = @cell_data[:illustration_count]
        "#{count} #{'example'.pluralize(count)}"
      end
    end
  end

  # Hidden detail content — revealed when cell is expanded
  def cell_detail
    div(class: "hidden mt-3 pt-3 border-t border-gray-100 dark:border-gray-800",
        data: { matrix_target: "cellDetail" }) do
      @cell_data[:illustrations_by_role].each do |role_id, illustrations|
        role = FrameworkState::Role.find_by(role_id: role_id)
        next unless role

        div(class: "mb-2 last:mb-0") do
          span(class: "text-[10px] font-mono font-medium text-gray-400 dark:text-gray-500 " \
                      "bg-gray-100 dark:bg-gray-800 rounded px-1.5 py-0.5") do
            role.code
          end
          ul(class: "mt-1 space-y-1") do
            illustrations.each do |ill|
              li(class: "text-xs text-gray-500 dark:text-gray-400 pl-3 relative " \
                        "before:content-[''] before:absolute before:left-0 before:top-1.5 " \
                        "before:w-1 before:h-1 before:rounded-full before:bg-gray-300 " \
                        "dark:before:bg-gray-600") do
                ill.description
              end
            end
          end
        end
      end
    end
  end
end
