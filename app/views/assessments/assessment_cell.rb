# frozen_string_literal: true

# Unified assessment matrix cell supporting self, manager, and alignment contexts.
#
# Shows the behavioural expectation text, a primary interactive frequency selector,
# 0-2 secondary read-only frequency bars, and an illustration indicator.
#
# The context determines which rating is primary (interactive) and which are
# secondary (read-only bars with divergence indicators).
#
# @example Self-assessment context
#   render Views::Assessments::AssessmentCell.new(
#     cell_data: cell, capability_stable_id: sid, ordinal: 2,
#     person_level: 3, assessment_id: fid, context: :self
#   )
#
class Views::Assessments::AssessmentCell < Views::Base
  # @param cell_data [Hash, nil] from MatrixDataBuilder — nil for empty cells
  # @param capability_stable_id [String]
  # @param ordinal [Integer] the level ordinal for this column
  # @param person_level [Integer] the person's assigned level ordinal
  # @param assessment_id [String]
  # @param context [Symbol] :self, :manager, or :alignment
  def initialize(cell_data:, capability_stable_id:, ordinal:, person_level:, assessment_id:, context: :self)
    @cell_data = cell_data
    @capability_stable_id = capability_stable_id
    @ordinal = ordinal
    @person_level = person_level
    @assessment_id = assessment_id
    @context = context
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
      secondary_bars
      primary_selector
      illustration_indicator if @cell_data[:illustration_count]&.positive?
    end
  end

  def expectation_text
    p(class: "text-sm text-gray-700 dark:text-gray-300 line-clamp-3") do
      @cell_data[:expectation].description
    end
  end

  # Interactive frequency selector for the primary rating.
  def primary_selector
    div(id: "rating-#{@capability_stable_id}-#{@ordinal}", class: "mt-2") do
      render Views::Assessments::FrequencySelector.new(
        capability_stable_id: @capability_stable_id,
        level_ordinal: @ordinal,
        current_frequency: primary_frequency,
        assessment_id: @assessment_id,
        context: @context
      )
    end
  end

  # Read-only bars for secondary rating perspectives.
  def secondary_bars
    bars = secondary_rating_entries
    return if bars.empty?

    div(class: "mt-1.5") do
      bars.each do |entry|
        render Views::Assessments::FrequencyBar.new(
          label: entry[:label],
          frequency: entry[:frequency],
          primary_frequency: primary_frequency
        )
      end
    end
  end

  # Returns the frequency value for the primary (interactive) context.
  #
  # @return [String, nil]
  def primary_frequency
    case @context
    when :self      then @cell_data[:current_frequency]
    when :manager   then @cell_data[:manager_frequency]
    when :alignment then @cell_data[:aligned_frequency]
    end
  end

  # Returns secondary rating entries to display as read-only bars.
  # Only includes entries that have a frequency value.
  #
  # @return [Array<Hash{label:, frequency:}>]
  def secondary_rating_entries
    entries = []

    case @context
    when :self
      entries << { label: "Mgr", frequency: @cell_data[:manager_frequency] }
      entries << { label: "Agreed", frequency: @cell_data[:aligned_frequency] }
    when :manager
      entries << { label: "Self", frequency: @cell_data[:current_frequency] }
      entries << { label: "Agreed", frequency: @cell_data[:aligned_frequency] }
    when :alignment
      entries << { label: "Self", frequency: @cell_data[:current_frequency] }
      entries << { label: "Mgr", frequency: @cell_data[:manager_frequency] }
    end

    entries.select { |e| e[:frequency].present? }
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

  # Cell background color based on the primary context's frequency.
  #
  # @return [String] Tailwind CSS classes
  def cell_background
    freq = primary_frequency
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
