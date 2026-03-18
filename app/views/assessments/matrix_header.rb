# frozen_string_literal: true

# Sticky header row for the assessment matrix.
# Shows "Capability" label + one column per level ordinal.
#
class Views::Assessments::MatrixHeader < Views::Base
  # @param merged_levels [Array<Hash>] from MatrixDataBuilder
  # @param person_level [Integer] the person's assigned level ordinal
  def initialize(merged_levels:, person_level:)
    @merged_levels = merged_levels
    @person_level = person_level
  end

  def view_template
    thead do
      tr do
        # Capability name column (sticky corner)
        th(class: "sticky top-0 left-0 z-20 bg-gray-50 dark:bg-gray-800 " \
                  "px-4 py-3 text-left text-xs font-semibold uppercase tracking-wider " \
                  "text-gray-500 dark:text-gray-400 border-b border-r " \
                  "border-gray-200 dark:border-gray-700 min-w-[220px]") do
          plain "Capability"
        end

        @merged_levels.each do |level|
          current = level[:ordinal] == @person_level
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
          end
        end
      end
    end
  end
end
