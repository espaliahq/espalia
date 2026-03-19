# frozen_string_literal: true

# Sticky header row for the assessment matrix.
# Shows "Capability" label + one column per level ordinal.
# For levels up to and including person_level + 1, also shows a meeting
# expectations chip (Mastering / Meeting / Below). For the three key levels
# (person_level - 1, person_level, person_level + 1) the exact score % is shown.
#
class Views::Assessments::MatrixHeader < Views::Base
  # @param merged_levels [Array<Hash>] from MatrixDataBuilder
  # @param person_level [Integer] the person's assigned level ordinal
  # @param meeting_expectation_threshold [Float] ratio threshold for "Meeting"
  # @param mastery_threshold [Float] ratio threshold for "Mastering"
  def initialize(merged_levels:, person_level:, meeting_expectation_threshold:, mastery_threshold:)
    @merged_levels = merged_levels
    @person_level = person_level
    @meeting_expectation_threshold = meeting_expectation_threshold
    @mastery_threshold = mastery_threshold
  end

  def view_template
    thead(id: "matrix-header") do
      tr do
        # Capability name column (sticky corner)
        th(class: "sticky top-0 left-0 z-20 bg-gray-50 dark:bg-gray-800 " \
                  "px-4 py-3 text-left text-xs font-semibold uppercase tracking-wider " \
                  "text-gray-500 dark:text-gray-400 border-b border-r " \
                  "border-gray-200 dark:border-gray-700 min-w-[220px]") do
          plain "Capability"
        end

        @merged_levels.each do |level|
          current   = level[:ordinal] == @person_level
          ratio     = level[:performance_ratio]
          key_level = [ @person_level - 1, @person_level, @person_level + 1 ].include?(level[:ordinal])

          th(class: "sticky top-0 z-10 bg-gray-50 dark:bg-gray-800 " \
                    "px-3 py-3 text-center text-xs font-semibold uppercase tracking-wider " \
                    "border-b border-r border-gray-200 dark:border-gray-700 " \
                    "min-w-[180px] #{current ? 'text-primary' : 'text-gray-500 dark:text-gray-400'}") do
            div { level[:level_code] }
            div(class: "font-normal normal-case mt-0.5") { level[:level_title] }
            if current
              span(class: "inline-block mt-1 text-[10px] bg-primary/10 text-primary " \
                          "rounded-full px-2 py-0.5") { "Your level" }
            end
            if ratio
              div(class: "mt-1.5 space-y-0.5") do
                level_expectations_chip(ratio)
                level_score_label(ratio) if key_level
              end
            end
          end
        end
      end
    end
  end

  private

  # Status chip rendered in each column header for levels up to person_level + 1.
  #
  # @param ratio [Float] performance_ratio_at_level result
  # @return [void]
  def level_expectations_chip(ratio)
    label, classes =
      if ratio >= @mastery_threshold
        [ "Mastering", "bg-purple-100 text-purple-700 dark:bg-purple-900/40 dark:text-purple-300" ]
      elsif ratio >= @meeting_expectation_threshold
        [ "Meeting",   "bg-green-100 text-green-700 dark:bg-green-900/40 dark:text-green-300" ]
      else
        [ "Below",     "bg-red-100 text-red-700 dark:bg-red-900/40 dark:text-red-300" ]
      end

    span(class: "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium #{classes}") { label }
  end

  # Exact percentage score — only shown for person_level ± 1.
  #
  # @param ratio [Float]
  # @return [void]
  def level_score_label(ratio)
    pct = (ratio * 100).round(0)
    span(class: "block text-[10px] font-mono text-gray-400 dark:text-gray-500") { "#{pct}%" }
  end
end
