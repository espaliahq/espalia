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
    td(
      id: "cell-#{@capability_stable_id}-#{@ordinal}",
      class: "px-3 py-2.5 border-b border-r border-gray-100 dark:border-gray-800 align-top " \
             "min-w-[180px] #{cell_background}"
    ) do
      expectation_text
      div(id: "rating-#{@capability_stable_id}-#{@ordinal}", class: "mt-2") do
        render Views::Assessments::FrequencySelector.new(
          capability_stable_id: @capability_stable_id,
          level_ordinal: @ordinal,
          current_frequency: @cell_data[:current_frequency],
          framework_id: @framework_id
        )
      end
      illustration_indicator if @cell_data[:illustration_count]&.positive?
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

  # Computes background color class based on rating vs level expectations.
  #
  # Below person_level:
  #   Unrated → muted green (assumed consistent by default)
  #   Consistent → solid green (explicitly rated)
  #   Occasional → amber (partial gap)
  #   Some → red (significant gap)
  #
  # At person_level (must be explicitly assessed):
  #   Unrated → neutral gray (no assumption)
  #   Consistent → solid green
  #   Occasional → amber
  #   Some → red
  #
  # Above person_level:
  #   Unrated → neutral gray (not expected)
  #   Consistent → green (exceeding)
  #   Occasional/Some → blue (stretch attempt)
  #
  # @return [String] Tailwind CSS classes
  def cell_background
    freq = @cell_data[:current_frequency]
    below = @ordinal < @person_level
    at_or_below = @ordinal <= @person_level

    if freq.nil?
      if below
        # Unrated below level — default assumes consistent, show muted green
        "bg-green-100/50 dark:bg-green-800/25"
      else
        # Unrated at current level or above — no assumption, neutral
        "bg-gray-50/50 dark:bg-gray-800/20"
      end
    elsif at_or_below
      case freq
      when "consistent" then "bg-green-100 dark:bg-green-900/30"
      when "occasional" then "bg-amber-100 dark:bg-amber-900/30"
      when "some"       then "bg-red-100 dark:bg-red-900/30"
      when "none"       then "bg-red-50 dark:bg-red-900/20"
      else ""
      end
    else
      case freq
      when "consistent" then "bg-green-100 dark:bg-green-900/30"
      when "none"       then "bg-red-50 dark:bg-red-900/20"
      else "bg-blue-100 dark:bg-blue-900/20"
      end
    end
  end
end
