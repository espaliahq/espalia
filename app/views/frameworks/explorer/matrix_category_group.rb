# frozen_string_literal: true

# Collapsible category group within the matrix.
#
# Renders a sticky category header row spanning all columns,
# followed by capability rows for this category.
#
class Views::Frameworks::Explorer::MatrixCategoryGroup < Views::Base
  include Views::Frameworks::Explorer::Concerns::SuggestionDecoration
  include Views::Frameworks::Explorer::Concerns::PendingArchive
  include Views::Frameworks::Explorer::Concerns::HoverCluster
  include Views::Frameworks::Explorer::Concerns::MenuItems
  include Views::Frameworks::Explorer::Concerns::StickyColumn

  # Turbo Stream anchor for the whole category — a `<tbody>`, so an archive can
  # remove it and a reorder can move the node in place.
  #
  # @param category_id [String]
  # @return [String]
  def self.group_id(category_id) = "category-group-#{category_id}"

  # Turbo Stream anchor a newly added capability's rows are inserted BEFORE —
  # the "+ Add capability" row always sits last in its category group.
  #
  # @param category_id [String]
  # @return [String]
  def self.add_capability_row_id(category_id) = "add-capability-row-#{category_id}"

  # @param category_data [Hash] from MatrixDataBuilder: { category:, capabilities: [...] }
  # @param merged_levels [Array<Hash>]
  # @param selected_role_ids [Array<String>]
  # @param framework_id [String] UUID of the framework (threaded to illustration inline editors)
  # @param mode [Symbol] :view or :edit
  def initialize(category_data:, merged_levels:, selected_role_ids:, framework_id:, mode: :view,
                 current_person_id: nil, search_query: nil, can_edit_structure: false,
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
    @current_person_id = current_person_id
    @search_query = search_query
    @can_edit_structure = can_edit_structure
    @approval_authority = approval_authority
  end

  # ONE `<tbody>` per category (valid HTML, and what makes a category
  # addressable): an add streams a whole group onto the table, an archive
  # removes one, and a reorder moves the node. Category collapse is unaffected
  # — matrix#toggleCategory walks siblings from the header row, which now stop
  # at the tbody boundary instead of at the next header.
  def view_template
    tbody(id: self.class.group_id(@category.category_id),
          data: { category_group: @category.category_id }) do
      category_header
      capability_rows
      add_capability_row if @mode == :edit && @can_edit_structure
    end
  end

  private

  # "+ Add capability" row at the foot of the category — opens the shared
  # add-capability modal, naming this category via the trigger dataset.
  #
  # Deliberately NOT `colspan`-ed across the table: a matrix-wide dashed box
  # puts its affordance wherever the row happens to be centred, which at the
  # default horizontal scroll is off-screen. It lives in the **capability
  # column** — the column it adds to — which the sticky left edge keeps in view
  # however far right the viewer has scrolled (#380 visual pass).
  def add_capability_row
    tr(id: self.class.add_capability_row_id(@category.category_id)) do
      td(
        class: "sticky left-0 z-[2] bg-white dark:bg-gray-900 #{STICKY_EDGE_CLASSES} " \
               "px-4 py-1.5 border-b border-gray-100 dark:border-gray-800 min-w-[200px]"
      ) do
        render_add_affordance(
          "Add capability",
          action: "click->modal#open",
          modal_target_id: "add-capability-modal",
          add_category_id: @category.category_id,
          add_category_name: @category.name
        )
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
        # Edit mode only — view mode has no hover controls to reveal.
        div(class: "flex items-start gap-2",
            data: (@mode == :edit ? hover_cluster_data("cat") : {})) do
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
            icon("chevron-right",
                 class: "w-3 h-3 text-gray-400 rotate-90 transition-transform",
                 data: { matrix_target: "categoryChevron" })
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

              category_actions_kebab if @mode == :edit
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

  # The category header's hover cluster. The pencils belong to the name /
  # description Turbo Frames (they travel with the frame); this is the ⋮ that
  # gathers everything else — Edit name/description (the touch stand-in for the
  # pencils), Move up / Move down (the ONE reorder treatment, replacing the old
  # ↑/↓ chevrons) and Archive… for an empty category.
  #
  # The kebab sits next to the NAME, not the far right of the full-width header,
  # which scrolls off-screen on a matrix with many level columns.
  def category_actions_kebab
    render_hover_cluster(
      scope: "cat",
      menu: { label: "Category actions", kind: "category", **category_menu_data }
    )
  end

  # Only what the client-side builder can't read off the header row (which
  # publishes `data-category-id`).
  def category_menu_data
    data = { name: @category.name }
    # Which Move directions exist is decided client-side from the sibling
    # `<tbody>` groups — a server-sent neighbour id goes stale as soon as the
    # first in-place move lands (framework-explorer.md §11a).
    data[:move] = "1" if @can_edit_structure
    data[:archive] = "1" if @can_edit_structure && @category_archivable
    data
  end

  def capability_rows
    @capabilities.each do |cap_data|
      render Views::Frameworks::Explorer::MatrixRow.new(
        capability_data: cap_data,
        merged_levels: @merged_levels,
        selected_role_ids: @selected_role_ids,
        framework_id: @framework_id,
        mode: @mode,
        current_person_id: @current_person_id,
        search_query: @search_query,
        can_edit_structure: @can_edit_structure,
        approval_authority: @approval_authority
      )
    end
  end
end
