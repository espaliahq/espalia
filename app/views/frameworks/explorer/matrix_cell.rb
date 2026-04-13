# frozen_string_literal: true

# Single cell in the capability × level matrix.
#
# Shows the behavioural expectation text and an illustration indicator.
# Illustrations are shown in the expanded row (managed by MatrixRow),
# not inline in the cell.
#
class Views::Frameworks::Explorer::MatrixCell < Views::Base
  include Views::Frameworks::Explorer::Concerns::SuggestionDecoration

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
    td(class: "px-3 py-2.5 border-b border-r border-gray-100 dark:border-gray-800 align-top") do
      expectation_text
      illustration_indicator if @cell_data[:illustration_count] > 0
    end
  end

  def expectation_text
    pending_count = @cell_data[:pending_suggestion_count] || 0
    decoration = suggestion_text_classes(pending_edit_count: pending_count)

    p(class: "text-sm text-gray-700 dark:text-gray-300 line-clamp-3 #{decoration}".strip) do
      @cell_data[:expectation].description
    end

    if pending_count >= 2
      render Views::Frameworks::Suggestions::InlineIndicator.new(count: pending_count)
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
end
