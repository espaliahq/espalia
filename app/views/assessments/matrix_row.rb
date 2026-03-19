# frozen_string_literal: true

# Single capability row in the assessment matrix.
# Shows capability name with weight/mandatory indicators + level cells with frequency selectors.
#
class Views::Assessments::MatrixRow < Views::Base
  # @param capability_data [Hash] from MatrixDataBuilder
  # @param merged_levels [Array<Hash>]
  # @param person_level [Integer]
  # @param framework_id [String]
  def initialize(capability_data:, merged_levels:, person_level:, framework_id:)
    @capability_data = capability_data
    @capability = capability_data[:capability]
    @binding = capability_data[:binding]
    @weight = capability_data[:weight]
    @mandatory = @binding.deficit_threshold&.to_f == 0.0
    @cells = capability_data[:cells]
    @merged_levels = merged_levels
    @person_level = person_level
    @framework_id = framework_id
  end

  def view_template
    tr(class: "hover:bg-gray-50 dark:hover:bg-gray-800/50 transition-colors " \
              "#{@mandatory ? 'border-l-3 border-l-amber-400' : ''}") do
      capability_name_cell
      @merged_levels.each do |level|
        render Views::Assessments::MatrixCell.new(
          cell_data: @cells[level[:ordinal]],
          capability_stable_id: @capability.stable_id,
          ordinal: level[:ordinal],
          person_level: @person_level,
          framework_id: @framework_id
        )
      end
    end
  end

  private

  def capability_name_cell
    td(class: "sticky left-0 z-[2] bg-white dark:bg-gray-900 " \
              "px-4 py-2.5 border-b border-r border-gray-100 dark:border-gray-800 " \
              "min-w-[220px] align-top " \
              "hover:bg-gray-50 dark:hover:bg-gray-800/50") do
      div(class: "flex items-start gap-2") do
        div do
          div(class: "flex items-center gap-1.5") do
            span(class: "text-sm font-medium text-gray-900 dark:text-white") { @capability.name }
            render Components::Kit::WeightBadge.new(weight: @weight, mandatory: @mandatory)
          end
          if @capability.description.present?
            p(class: "text-xs text-gray-500 dark:text-gray-400 mt-0.5 line-clamp-2") do
              @capability.description
            end
          end
        end
      end
    end
  end
end
