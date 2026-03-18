# frozen_string_literal: true

# Single cell in the assessment matrix.
#
# Shows the behavioural expectation text + frequency selector for self-rating.
# Background color reflects the rating relative to expectations at this level:
#
# At/below person_level: green (consistent), amber (occasional), red (some), gray (unrated)
# Above person_level: green (consistent), blue (stretch attempt), neutral (unrated)
#
class Views::Assessments::MatrixCell < Views::Base
  # @param cell_data [Hash, nil] from MatrixDataBuilder — nil for empty cells
  # @param capability_stable_id [String]
  # @param ordinal [Integer] the level ordinal for this column
  # @param person_level [Integer] the person's assigned level ordinal
  # @param framework_id [String]
  def initialize(cell_data:, capability_stable_id:, ordinal:, person_level:, framework_id:)
    @cell_data = cell_data
    @capability_stable_id = capability_stable_id
    @ordinal = ordinal
    @person_level = person_level
    @framework_id = framework_id
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
    td(class: "px-3 py-2.5 border-b border-r border-gray-100 dark:border-gray-800 align-top " \
              "min-w-[180px] #{cell_background}") do
      expectation_text
      div(id: "rating-#{@capability_stable_id}-#{@ordinal}", class: "mt-2") do
        render Views::Assessments::FrequencySelector.new(
          capability_stable_id: @capability_stable_id,
          level_ordinal: @ordinal,
          current_frequency: @cell_data[:current_frequency],
          framework_id: @framework_id
        )
      end
    end
  end

  def expectation_text
    p(class: "text-sm text-gray-700 dark:text-gray-300 line-clamp-3") do
      @cell_data[:expectation].description
    end
  end

  # Computes background color class based on rating vs level expectations.
  #
  # @return [String] Tailwind CSS classes
  def cell_background
    freq = @cell_data[:current_frequency]
    at_or_below = @ordinal <= @person_level

    if freq.nil?
      # Unrated
      at_or_below ? "bg-gray-50 dark:bg-gray-800/30" : "bg-gray-50/50 dark:bg-gray-800/20"
    elsif at_or_below
      # At or below person level — consistent is expected
      case freq
      when "consistent" then "bg-green-50 dark:bg-green-900/15"
      when "occasional" then "bg-amber-50 dark:bg-amber-900/15"
      when "some"       then "bg-red-50 dark:bg-red-900/15"
      else ""
      end
    else
      # Above person level — any rating is stretch
      freq == "consistent" ? "bg-green-50 dark:bg-green-900/15" : "bg-blue-50 dark:bg-blue-900/10"
    end
  end
end
