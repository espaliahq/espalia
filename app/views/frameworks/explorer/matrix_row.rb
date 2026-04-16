# frozen_string_literal: true

# Single capability row in the matrix.
#
# Renders two <tr> elements:
# 1. Compact row (always visible): capability name + expectation text per level cell
# 2. Expanded row (hidden by default): full illustrations for each cell
#
class Views::Frameworks::Explorer::MatrixRow < Views::Base
  include Views::Frameworks::Explorer::Concerns::SuggestionDecoration

  # @param capability_data [Hash] from MatrixDataBuilder
  # @param merged_levels [Array<Hash>]
  # @param selected_role_ids [Array<String>]
  # @param framework_id [String] UUID of the framework (for illustration PATCH URLs)
  def initialize(capability_data:, merged_levels:, selected_role_ids:, framework_id:)
    @capability_data = capability_data
    @merged_levels = merged_levels
    @selected_role_ids = selected_role_ids
    @framework_id = framework_id
    @capability = capability_data[:capability]
    @bound = capability_data[:bound_to_selected]
    @cells = capability_data[:cells]
    @capability_pending_count = capability_data[:pending_suggestion_count] || 0
  end

  def view_template
    compact_row
    expanded_row
  end

  private

  def compact_row
    tr(
      class: "#{@bound ? '' : 'opacity-50'} group cursor-pointer " \
             "hover:bg-gray-50 dark:hover:bg-gray-800/50 transition-colors",
      data: {
        action: "click->matrix#toggleRow",
        matrix_target: "row",
        capability_id: @capability.capability_id
      }
    ) do
      # Capability name (sticky left column)
      td(class: "sticky left-0 z-[2] bg-white dark:bg-gray-900 " \
                "px-4 py-2.5 border-b border-r border-gray-100 dark:border-gray-800 " \
                "min-w-[200px] align-top group-hover:bg-gray-50 dark:group-hover:bg-gray-800/50") do
        div(class: "flex items-start gap-2") do
          # Expand indicator
          svg(
            class: "w-3 h-3 mt-1 text-gray-400 transition-transform shrink-0",
            data: { matrix_target: "rowChevron" },
            fill: "none", viewBox: "0 0 24 24", stroke: "currentColor", stroke_width: "2"
          ) do |s|
            s.path(d: "M9 5l7 7-7 7")
          end

          div do
            decoration = suggestion_text_classes(pending_edit_count: @capability_pending_count)
            span(class: "text-sm font-medium text-gray-900 dark:text-white #{decoration}".strip) { @capability.name }
            p(class: "text-xs text-gray-500 dark:text-gray-400 mt-0.5 line-clamp-1") do
              @capability.description
            end if @capability.description.present?
          end
        end
      end

      # Level cells
      @merged_levels.each do |level|
        render Views::Frameworks::Explorer::MatrixCell.new(
          cell_data: @cells[level[:ordinal]],
          ordinal: level[:ordinal]
        )
      end
    end
  end

  def expanded_row
    tr(
      class: "hidden",
      data: { matrix_target: "expandedRow", capability_id: @capability.capability_id }
    ) do
      # Empty sticky column
      td(class: "sticky left-0 z-[2] bg-blue-50/30 dark:bg-blue-900/10 " \
                "border-b border-r border-gray-100 dark:border-gray-800") { }

      # Expanded cells with full illustrations
      @merged_levels.each do |level|
        expanded_cell(level[:ordinal])
      end
    end
  end

  def expanded_cell(ordinal) # rubocop:disable Metrics/MethodLength
    cell_data = @cells[ordinal]

    if cell_data.nil? || cell_data[:bound_selected_role_ids].blank?
      td(class: "px-3 py-2 border-b border-r border-gray-100 dark:border-gray-800 " \
                "bg-blue-50/30 dark:bg-blue-900/10 align-top") { }
      return
    end

    expectation = cell_data[:expectation]

    td(
      class: "px-3 py-2 border-b border-r border-gray-100 dark:border-gray-800 " \
             "bg-blue-50/30 dark:bg-blue-900/10 align-top cursor-pointer " \
             "hover:bg-blue-100/50 dark:hover:bg-blue-900/20 transition-colors",
      data: {
        action: "click->matrix#focusCell",
        capability_id: @capability.capability_id,
        level_ordinal: ordinal,
        expectation_id: expectation.expectation_id
      }
    ) do
      ill_pending_edits = cell_data[:illustration_pending_edits] || {}
      pending_creates = cell_data[:pending_illustration_creates] || []

      cell_data[:bound_selected_role_ids].each do |role_id|
        role = FrameworkState::Role.find_by(role_id: role_id)
        next unless role

        illustrations = cell_data[:illustrations_by_role][role_id] || []
        role_pending_creates = pending_creates.select { |s| s.proposed_attributes["role_id"] == role_id }

        div(class: "mb-2 last:mb-0") do
          render Components::Kit::Badge.new(role.code, variant: :default)
          ul(
            id: "illustrations-#{expectation.expectation_id}-#{role_id}",
            class: "mt-1 space-y-1"
          ) do
            illustrations.each do |ill|
              render Views::Frameworks::Explorer::IllustrationFrame.new(
                illustration: ill,
                framework_id: @framework_id,
                pending_edit_count: ill_pending_edits[ill.illustration_id] || 0
              )
            end
            role_pending_creates.each do |suggestion|
              render Views::Frameworks::Explorer::PendingIllustrationFrame.new(
                suggestion: suggestion,
                framework_id: @framework_id
              )
            end
          end
          render Views::Frameworks::Explorer::NewIllustrationFrame.new(
            expectation_id: expectation.expectation_id,
            role_id: role_id,
            framework_id: @framework_id
          )
        end
      end
    end
  end
end
