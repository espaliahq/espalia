# frozen_string_literal: true

# Single cell in the manager assessment matrix.
#
# Shows the behavioural expectation text, the assessee's self-rating (read-only pill),
# and a frequency selector for the manager's rating.
#
class Views::Assessments::ManagerMatrixCell < Views::Base
  SELF_RATING_LABELS = {
    "none" => { label: "None", class: "bg-gray-100 text-gray-600 dark:bg-gray-700 dark:text-gray-300" },
    "some" => { label: "Some", class: "bg-amber-100 text-amber-700 dark:bg-amber-900/30 dark:text-amber-300" },
    "occasional" => { label: "Occ.", class: "bg-blue-100 text-blue-700 dark:bg-blue-900/30 dark:text-blue-300" },
    "consistent" => { label: "Cons.", class: "bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-300" }
  }.freeze

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
      self_rating_indicator
      div(id: "rating-#{@capability_stable_id}-#{@ordinal}", class: "mt-2") do
        render Views::Assessments::ManagerFrequencySelector.new(
          capability_stable_id: @capability_stable_id,
          level_ordinal: @ordinal,
          current_frequency: @cell_data[:manager_frequency],
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

  # Read-only pill showing the assessee's self-rating.
  def self_rating_indicator
    freq = @cell_data[:current_frequency]
    return unless freq

    info = SELF_RATING_LABELS[freq]
    return unless info

    div(class: "mt-1.5 flex items-center gap-1") do
      span(class: "text-[10px] text-gray-400 dark:text-gray-500") { "Self:" }
      span(class: "px-1.5 py-0.5 text-[10px] font-medium rounded #{info[:class]}") do
        info[:label]
      end
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

  # Background color based on manager's rating (same logic as self-assessment cell).
  #
  # @return [String] Tailwind CSS classes
  def cell_background
    freq = @cell_data[:manager_frequency]
    below = @ordinal < @person_level
    at_or_below = @ordinal <= @person_level

    if freq.nil?
      if below
        "bg-green-100/50 dark:bg-green-800/25"
      else
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
