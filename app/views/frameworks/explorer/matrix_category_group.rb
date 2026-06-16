# frozen_string_literal: true

# Collapsible category group within the matrix.
#
# Renders a sticky category header row spanning all columns,
# followed by capability rows for this category.
#
class Views::Frameworks::Explorer::MatrixCategoryGroup < Views::Base
  include Views::Frameworks::Explorer::Concerns::SuggestionDecoration

  # @param category_data [Hash] from MatrixDataBuilder: { category:, capabilities: [...] }
  # @param merged_levels [Array<Hash>]
  # @param selected_role_ids [Array<String>]
  # @param framework_id [String] UUID of the framework (threaded to illustration inline editors)
  # @param mode [Symbol] :view or :edit
  # @param roles_by_id [Hash] { role_id => Role } — passed through to rows to avoid per-cell AR lookups
  def initialize(category_data:, merged_levels:, selected_role_ids:, framework_id:, mode: :view,
                 roles_by_id: {}, current_person_id: nil, search_query: nil, can_edit_structure: false,
                 approval_authority: Frameworks::SuggestionApprovalAuthority.none)
    @category = category_data[:category]
    @capabilities = category_data[:capabilities]
    @category_pending_count = category_data[:pending_suggestion_count] || 0
    @category_pending_edit = category_data[:pending_edit]
    @category_description_pending_edit = category_data[:description_pending_edit]
    @category_archivable = category_data[:archivable]
    @merged_levels = merged_levels
    @selected_role_ids = selected_role_ids
    @framework_id = framework_id
    @mode = mode
    @roles_by_id = roles_by_id
    @current_person_id = current_person_id
    @search_query = search_query
    @can_edit_structure = can_edit_structure
    @approval_authority = approval_authority
  end

  def view_template
    category_header
    capability_rows
    add_capability_row if @mode == :edit && @can_edit_structure
  end

  private

  # "+ Add capability" row at the foot of the category — opens the shared
  # add-capability modal, naming this category via the trigger dataset.
  def add_capability_row
    tr do
      td(
        colspan: @merged_levels.size + 1,
        class: "sticky left-0 px-4 py-1.5 border-b border-gray-100 dark:border-gray-800 " \
               "bg-white dark:bg-gray-900"
      ) do
        button(
          type: "button",
          class: "inline-flex items-center gap-1 text-xs font-medium text-primary hover:underline",
          data: {
            action: "click->modal#open",
            modal_target_id: "add-capability-modal",
            add_category_id: @category.category_id,
            add_category_name: @category.name
          }
        ) do
          span(class: "text-sm leading-none") { "+" }
          plain "Add capability"
        end
      end
    end
  end

  def category_header
    col_count = @merged_levels.size + 1 # +1 for capability name column

    tr(
      class: "sticky top-[41px] z-[5]",
      data: {
        matrix_target: "categoryHeader",
        category_id: @category.category_id
      }
    ) do
      td(
        colspan: col_count,
        class: "px-4 py-2 bg-gray-100 dark:bg-gray-800 border-b border-gray-200 dark:border-gray-700"
      ) do
        div(class: "group flex items-start gap-2") do
          # Chevron collapses/expands the category rows
          button(
            type: "button",
            class: "flex items-center justify-center w-4 h-4 mt-0.5 cursor-pointer rounded " \
                   "hover:bg-gray-200 dark:hover:bg-gray-700",
            data: {
              action: "click->matrix#toggleCategory",
              category_id: @category.category_id
            },
            aria_label: "Toggle category"
          ) do
            svg(
              class: "w-3 h-3 text-gray-400 rotate-90 transition-transform",
              data: { matrix_target: "categoryChevron" },
              fill: "none", viewBox: "0 0 24 24", stroke: "currentColor", stroke_width: "2"
            ) do |s|
              s.path(d: "M9 5l7 7-7 7")
            end
          end

          # Name + count row, with the (optionally inline-editable) description
          # stacked underneath — aligned under the name, past the chevron.
          div(class: "min-w-0") do
            # Name + count (the focus hit target) and the archive kebab share one
            # row. The kebab sits next to the name — NOT pushed to the far right
            # of the full-width category header, which scrolls off-screen on a
            # matrix with many level columns.
            div(class: "flex items-center gap-1") do
              # A span with role=button — NOT a <button> — so the edit-mode name
              # frame (which nests an inline-editor <form> + pencil <button>) is
              # valid HTML inside it. A <button> ancestor makes the browser
              # reparent that nested interactive content out, which both breaks
              # the name's inline editor and distorts the header layout.
              # focusCategory ignores clicks on those interactive children, and
              # keydown.enter keeps the focus action keyboard-reachable.
              span(
                role: "button",
                tabindex: "0",
                class: "flex items-center gap-2 cursor-pointer hover:underline text-left",
                data: {
                  action: "click->matrix#focusCategory keydown.enter->matrix#focusCategory",
                  category_id: @category.category_id
                }
              ) do
                render Views::Frameworks::Explorer::CategoryNameFrame.new(
                  category: @category,
                  framework_id: @framework_id,
                  mode: @mode,
                  pending_edit_count: @category_pending_count,
                  pending_edit: @category_pending_edit,
                  search_query: @search_query
                )

                span(class: "text-xs text-gray-600 dark:text-gray-300") do
                  "#{@capabilities.size} #{'capability'.pluralize(@capabilities.size)}"
                end
              end

              archive_category_kebab if show_archive_category_kebab?
            end

            # Description: inline-editable in edit mode (also shown when blank,
            # as an "Add a description…" affordance). View mode renders it only
            # when present.
            if @mode == :edit || @category.description.present?
              render Views::Frameworks::Explorer::CategoryDescriptionFrame.new(
                category: @category,
                framework_id: @framework_id,
                mode: @mode,
                pending_edit: @category_description_pending_edit,
                pending_edit_count: @category_description_pending_edit ? 1 : 0,
                search_query: @search_query
              )
            end
          end
        end
      end
    end
  end

  # Archive affordance — edit mode, edit-structure rights, and only when the
  # category holds no active capabilities (the aggregate refuses otherwise, so
  # we don't offer it). Hover-revealed at the right of the header; opens the
  # shared archive-category modal, naming this category via the trigger dataset.
  def show_archive_category_kebab?
    @mode == :edit && @can_edit_structure && @category_archivable
  end

  def archive_category_kebab
    button(
      type: "button",
      class: "opacity-0 group-hover:opacity-100 focus-visible:opacity-100 " \
             "transition-opacity inline-flex items-center justify-center w-5 h-5 rounded shrink-0 " \
             "text-gray-400 hover:text-primary",
      data: {
        action: "click->modal#open",
        modal_target_id: "archive-category-modal",
        archive_category_id: @category.category_id,
        archive_category_name: @category.name
      },
      aria_label: "Archive category"
    ) do
      svg(
        class: "w-4 h-4", fill: "none", viewBox: "0 0 24 24",
        stroke: "currentColor", stroke_width: "2"
      ) do |s|
        s.path(
          stroke_linecap: "round", stroke_linejoin: "round",
          d: "M20.25 7.5l-.625 10.632a2.25 2.25 0 01-2.247 2.118H6.622a2.25 2.25 0 " \
             "01-2.247-2.118L3.75 7.5M10 11.25h4M3.375 7.5h17.25c.621 0 1.125-.504 " \
             "1.125-1.125v-1.5c0-.621-.504-1.125-1.125-1.125H3.375c-.621 0-1.125.504-1.125 " \
             "1.125v1.5c0 .621.504 1.125 1.125 1.125z"
        )
      end
    end
  end

  def capability_rows
    @capabilities.each do |cap_data|
      render Views::Frameworks::Explorer::MatrixRow.new(
        capability_data: cap_data,
        merged_levels: @merged_levels,
        selected_role_ids: @selected_role_ids,
        framework_id: @framework_id,
        mode: @mode,
        roles_by_id: @roles_by_id,
        current_person_id: @current_person_id,
        search_query: @search_query,
        can_edit_structure: @can_edit_structure,
        approval_authority: @approval_authority
      )
    end
  end
end
