# frozen_string_literal: true

# The capability × level matrix table.
#
# Renders a table with sticky column headers and category groups,
# each containing expandable capability rows with level cells.
#
class Views::Frameworks::Explorer::Matrix < Views::Base
  # @param matrix_data [Hash] output from MatrixDataBuilder
  # @param selected_role_ids [Array<String>]
  # @param framework_id [String] UUID of the framework (threaded to illustration inline editors)
  # @param mode [Symbol] :view or :edit
  def initialize(matrix_data:, selected_role_ids:, framework_id:, mode: :view,
                 current_person_id: nil, can_edit_structure: false)
    @matrix_data = matrix_data
    @selected_role_ids = selected_role_ids
    @framework_id = framework_id
    @mode = mode
    @current_person_id = current_person_id
    @can_edit_structure = can_edit_structure
    @merged_levels = matrix_data[:merged_levels]
    @categories = matrix_data[:categories]
    # Prebuild role lookup so expanded cells don't hit AR once per bound
    # role per row — that was adding N+1 queries on edit-mode render.
    @roles_by_id = matrix_data[:selected_roles].index_by(&:role_id)
  end

  def view_template
    if @merged_levels.empty?
      empty_state
    elsif @categories.empty? && @matrix_data[:search_query].present?
      no_matches_state
    else
      search_summary if @matrix_data[:search_query].present?
      matrix_table
    end
  end

  private

  # Live "Showing N of M" line, rendered inside the matrix Turbo Frame so it
  # updates on every filter change (the header stats bar sits outside the
  # frame and can't). Only shown while a text filter is active.
  def search_summary
    matched = @matrix_data[:matched_capability_count]
    total = @matrix_data[:in_scope_capability_count]

    div(class: "flex items-center gap-1.5 px-4 py-2 " \
               "bg-amber-50 dark:bg-amber-900/20 border-b border-amber-200 dark:border-amber-800 " \
               "text-xs text-amber-800 dark:text-amber-200") do
      span(class: "font-semibold") { "Showing #{matched} of #{total}" }
      plain " capabilities matching "
      span(class: "font-semibold") { "“#{@matrix_data[:search_query]}”" }
    end
  end

  def matrix_table
    table(class: "w-full border-collapse") do
      render Views::Frameworks::Explorer::MatrixHeader.new(
        merged_levels: @merged_levels,
        selected_role_count: @matrix_data[:selected_roles].size
      )
      tbody do
        @categories.each do |cat_data|
          render Views::Frameworks::Explorer::MatrixCategoryGroup.new(
            category_data: cat_data,
            merged_levels: @merged_levels,
            selected_role_ids: @selected_role_ids,
            framework_id: @framework_id,
            mode: @mode,
            roles_by_id: @roles_by_id,
            current_person_id: @current_person_id,
            search_query: @matrix_data[:search_query],
            can_edit_structure: @can_edit_structure
          )
        end
      end
    end
  end

  def empty_state
    div(class: "flex items-center justify-center h-64") do
      div(class: "text-center") do
        p(class: "text-gray-600 dark:text-gray-300 text-sm") do
          "Select roles from the tree to view the capability matrix."
        end
      end
    end
  end

  # Shown when a text filter is active but no in-scope capability matches.
  # Offers escapes along both filter axes — drop the query (keep the role
  # scope) or reset to all roles. Both break out of the matrix Turbo Frame
  # (`_top`) so the header search box + browser URL reset cleanly.
  def no_matches_state
    div(class: "flex items-center justify-center h-64") do
      div(class: "text-center max-w-sm px-6") do
        p(class: "text-gray-900 dark:text-white text-sm font-medium") do
          plain "No capabilities match "
          span(class: "font-semibold") { "“#{@matrix_data[:search_query]}”" }
          plain " for the selected roles."
        end
        div(class: "mt-3 flex items-center justify-center gap-4 text-sm") do
          a(href: reset_path(@selected_role_ids), data: { turbo_frame: "_top" },
            class: "text-primary hover:underline font-medium") { "Clear search" }
          a(href: reset_path([]), data: { turbo_frame: "_top" },
            class: "text-gray-600 dark:text-gray-300 hover:underline") { "Show all roles" }
        end
      end
    end
  end

  # Full-page path back to the explorer (mode-aware) with the given role
  # scope and no query — drives both escape links above. Preserves the active
  # track filter (the only other URL-encoded axis; role-family scope is carried
  # by `roles[]`) so clearing the search doesn't silently reset IC/Mgmt.
  def reset_path(role_ids)
    params = { roles: role_ids }
    track = @matrix_data[:track_filter]
    params[:track] = track if track.present? && track != "both"

    if @mode == :edit
      edit_framework_path(@framework_id, **params)
    else
      framework_path(@framework_id, **params)
    end
  end
end
