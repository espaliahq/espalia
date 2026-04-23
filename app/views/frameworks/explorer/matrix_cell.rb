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
  # @param framework_id [String] UUID — required when mode is :edit for the expectation edit URL
  # @param mode [Symbol] :view or :edit
  def initialize(cell_data:, ordinal:, framework_id: nil, mode: :view)
    @cell_data = cell_data
    @ordinal = ordinal
    @framework_id = framework_id
    @mode = mode
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
    expectation = @cell_data[:expectation]

    render Views::Frameworks::Explorer::ExpectationTextFrame.new(
      expectation: expectation,
      framework_id: @framework_id,
      mode: @mode,
      pending_edit_count: pending_count,
      pending_edit: @cell_data[:pending_edit]
    )

    if @mode == :edit && expectation.respond_to?(:added_in_draft) && expectation.added_in_draft
      span(class: "mt-1 inline-flex items-center rounded-full px-2 py-0.5 " \
                  "text-[10px] font-semibold bg-emerald-100 text-emerald-700 " \
                  "dark:bg-emerald-900/30 dark:text-emerald-300") { "New in draft" }
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
