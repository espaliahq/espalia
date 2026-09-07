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
                 current_person_id: nil, can_edit_structure: false,
                 approval_authority: Frameworks::SuggestionApprovalAuthority.none)
    @matrix_data = matrix_data
    @selected_role_ids = selected_role_ids
    @framework_id = framework_id
    @mode = mode
    @current_person_id = current_person_id
    @can_edit_structure = can_edit_structure
    @approval_authority = approval_authority
    @merged_levels = matrix_data[:merged_levels]
    @categories = matrix_data[:categories]
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
    # The role/track scope every on-demand expanded-row fetch appends to its
    # row's `data-expanded-src` — carried ONCE here rather than once per row
    # (Hard-Won Lesson 25).
    table(class: "w-full border-collapse", data: { expanded_row_scope: expanded_row_scope }) do
      render Views::Frameworks::Explorer::MatrixHeader.new(
        merged_levels: @merged_levels,
        selected_role_count: @matrix_data[:selected_roles].size,
        framework_id: @framework_id,
        mode: @mode
      )
      tbody do
        @categories.each_with_index do |cat_data, index|
          render Views::Frameworks::Explorer::MatrixCategoryGroup.new(
            category_data: cat_data,
            merged_levels: @merged_levels,
            selected_role_ids: @selected_role_ids,
            framework_id: @framework_id,
            mode: @mode,
            current_person_id: @current_person_id,
            search_query: @matrix_data[:search_query],
            can_edit_structure: @can_edit_structure,
            approval_authority: @approval_authority,
            # Visible neighbours for the header's ↑/↓ move chevrons — a move is
            # relative to what the viewer SEES (filters can hide categories),
            # and the matrix re-renders after each move so these stay fresh.
            prev_category_id: index.positive? ? @categories[index - 1][:category].category_id : nil,
            next_category_id: @categories[index + 1]&.dig(:category)&.category_id
          )
        end
      end
    end
  end

  # Query string of the scope the matrix was rendered under — the same
  # role/track selection the expanded rows must be fetched with. Defaults
  # (all roles, both tracks) are omitted so the common case is empty.
  #
  # @return [String]
  def expanded_row_scope
    scope_params(@selected_role_ids).to_query
  end

  # @return [Hash] `roles` / `track` as the explorer URLs carry them
  def scope_params(role_ids)
    params = {}
    params[:roles] = role_ids if role_ids.present?
    track = @matrix_data[:track_filter]
    params[:track] = track if track.present? && track != "both"
    params
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
    params = scope_params(role_ids).merge(roles: role_ids)

    if @mode == :edit
      edit_framework_path(@framework_id, **params)
    else
      framework_path(@framework_id, **params)
    end
  end
end
