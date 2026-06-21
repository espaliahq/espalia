# frozen_string_literal: true

# Sticky column headers for the capability × level matrix.
#
# Renders the <thead> with level ordinals and role code badges.
# When few roles are selected (≤ 3), shows full level titles.
# When many roles are selected, shows compact level codes.
#
class Views::Frameworks::Explorer::MatrixHeader < Views::Base
  # Threshold: show full titles when this many or fewer distinct roles
  FULL_TITLE_THRESHOLD = 3

  # @param merged_levels [Array<Hash>] from MatrixDataBuilder
  # @param selected_role_count [Integer] number of selected roles
  # @param framework_id [String, nil] required in :edit mode for inline-edit form actions
  # @param mode [Symbol] :view or :edit — gates the inline level-title rename pencils
  def initialize(merged_levels:, selected_role_count: 0, framework_id: nil, mode: :view)
    @merged_levels = merged_levels
    @framework_id = framework_id
    @mode = mode
    @show_full_titles = selected_role_count <= FULL_TITLE_THRESHOLD
  end

  def view_template
    thead do
      tr(class: "bg-gray-50 dark:bg-gray-900") do
        corner_cell
        @merged_levels.each { |level| level_column(level) }
      end
    end
  end

  private

  def corner_cell
    th(class: "sticky top-0 left-0 z-20 bg-gray-50 dark:bg-gray-900 " \
              "px-4 py-3 text-left text-xs font-medium text-gray-600 dark:text-gray-300 " \
              "uppercase tracking-wide border-b border-r border-gray-200 dark:border-gray-700 " \
              "min-w-[200px]") do
      "Capability"
    end
  end

  def level_column(level)
    th(class: "sticky top-0 z-10 bg-gray-50 dark:bg-gray-900 " \
              "px-3 py-3 text-center border-b border-r border-gray-200 dark:border-gray-700 " \
              "min-w-[180px]") do
      div(class: "text-sm font-semibold text-gray-900 dark:text-white mb-1") do
        "Level #{level[:ordinal]}"
      end

      if @show_full_titles
        full_title_badges(level[:role_codes])
      else
        compact_code_badges(level[:role_codes])
      end
    end
  end

  # Shows full level titles (e.g. "Associate Product Designer") when few roles
  # selected. In edit mode each per-role title is an inline-editable frame keyed
  # by its level_id (the compact-code view below stays read-only).
  def full_title_badges(role_codes)
    div(class: "flex flex-col items-center gap-0.5") do
      role_codes.each do |rc|
        if @mode == :edit && rc[:level_id]
          render Views::Frameworks::Explorer::LevelTitleFrame.new(
            level_id: rc[:level_id], title: rc[:level_title],
            framework_id: @framework_id, mode: @mode
          )
        else
          span(class: "text-xs text-gray-600 dark:text-gray-300") { rc[:level_title] }
        end
      end
    end
  end

  # Shows compact code badges (e.g. "PD1", "E1") when many roles selected
  def compact_code_badges(role_codes)
    div(class: "flex flex-wrap justify-center gap-1") do
      role_codes.each do |rc|
        span(
          class: "inline-flex items-center rounded-full px-2 py-0.5 " \
                 "text-[10px] font-medium bg-gray-200 dark:bg-gray-700 " \
                 "text-gray-600 dark:text-gray-300",
          title: rc[:level_title]
        ) { rc[:level_code] }
      end
    end
  end
end
