# frozen_string_literal: true

# Single capability row in the matrix.
#
# Renders two <tr> elements:
# 1. Compact row (always visible): capability name + expectation text per level cell
# 2. Expanded row (hidden by default): a placeholder that fetches the full
#    illustrations for each cell the first time the row is expanded — see
#    {Views::Frameworks::Explorer::ExpandedRow}
#
class Views::Frameworks::Explorer::MatrixRow < Views::Base
  include Views::Frameworks::Explorer::Concerns::StickyColumn
  include Views::Frameworks::Explorer::Concerns::SuggestionDecoration
  include Views::Frameworks::Explorer::Concerns::SearchHighlight
  include Views::Frameworks::Explorer::Concerns::HoverCluster
  include Views::Frameworks::Explorer::Concerns::MenuItems
  include Views::Frameworks::Explorer::Concerns::DiscussTrigger
  include Views::Frameworks::Explorer::Concerns::PendingArchive

  # Turbo Stream anchor for the compact row — an archive replaces it (struck +
  # "Pending archive"), an add inserts a fresh pair before the category's
  # "+ Add capability" row.
  #
  # @param capability_id [String]
  # @return [String]
  def self.compact_row_id(capability_id) = "capability-row-#{capability_id}"

  # @param capability_data [Hash] from MatrixDataBuilder
  # @param merged_levels [Array<Hash>]
  # @param selected_role_ids [Array<String>]
  # @param framework_id [String] UUID of the framework (for illustration PATCH URLs)
  # @param mode [Symbol] :view or :edit
  # @param include_expanded_row [Boolean] false when a Turbo Stream is replacing
  #   ONLY the compact row (an archive) — the hidden expanded row is left where
  #   it is so already-fetched content and the accordion state survive
  def initialize(capability_data:, merged_levels:, selected_role_ids:, framework_id:, mode: :view,
                 current_person_id: nil, search_query: nil, can_edit_structure: false,
                 approval_authority: Frameworks::SuggestionApprovalAuthority.none,
                 include_expanded_row: true)
    @capability_data = capability_data
    @merged_levels = merged_levels
    @selected_role_ids = selected_role_ids
    @framework_id = framework_id
    @mode = mode
    @current_person_id = current_person_id
    @search_query = search_query
    @can_edit_structure = can_edit_structure
    @approval_authority = approval_authority
    @include_expanded_row = include_expanded_row
    @capability = capability_data[:capability]
    @bound = capability_data[:bound_to_selected]
    @cells = capability_data[:cells]
    @capability_pending_count = capability_data[:pending_suggestion_count] || 0
    @capability_pending_edit = capability_data[:pending_edit]
    @description_pending_edit = capability_data[:description_pending_edit]
    # Struck through (edit mode only) when the capability is staged for archive
    # in the open draft — the "going away on publish" affordance. Still carries
    # the "Pending archive" badge for the explicit label.
    @struck = struck?(@capability, @mode)
  end

  def view_template
    compact_row
    expanded_row if @include_expanded_row
  end

  private

  def strikethrough_classes
    @struck ? STRIKETHROUGH_CLASSES : ""
  end

  def compact_row
    tr(
      id: self.class.compact_row_id(@capability.capability_id),
      class: "#{@bound ? '' : 'opacity-50'} #{strikethrough_classes} group cursor-pointer scroll-mt-20 " \
             "hover:bg-gray-50 dark:hover:bg-gray-800/50 transition-colors",
      # The cluster attribute only earns its bytes in edit mode — view mode has
      # no hover controls to reveal.
      data: (@mode == :edit ? hover_cluster_data("row") : {}).merge(
        {
          action: "click->matrix#toggleRow",
          matrix_target: "row",
          capability_id: @capability.capability_id,
          # Published once per row so the row's and its cells' menus can build
          # their "Discuss…" context label without repeating the name per cell.
          capability_name: @capability.name,
          # A reorder target. Read from the DOM by the kebab's Move items — NOT
          # from a server-sent neighbour id, which goes stale the moment the
          # first in-place move lands (the illustration menu learned this first;
          # framework-explorer.md §11a).
          movable: (@mode == :edit && !@struck) ? "true" : nil
        }.compact
      )
    ) do
      # Capability name (sticky left column)
      # Every background here is OPAQUE, hover included — a sticky cell with a
      # translucent background lets horizontally-scrolled content render
      # straight through it (see framework-explorer.md, Hard-Won Lesson 24).
      # #172131 is gray-800/50 composited over gray-900, so the hovered sticky
      # cell matches the rest of the hovered row exactly.
      td(class: "sticky left-0 z-[2] bg-white dark:bg-gray-900 " \
                "#{STICKY_EDGE_CLASSES} " \
                "px-4 py-2.5 border-b border-r border-gray-100 dark:border-gray-800 " \
                "min-w-[200px] align-top group-hover:bg-gray-50 dark:group-hover:bg-[#172131]") do
        div(class: "flex items-start gap-2") do
          # Expand indicator
          icon("chevron-right",
               class: "w-3 h-3 mt-1 text-gray-400 transition-transform shrink-0",
               data: { matrix_target: "rowChevron" })

          div do
            div(class: "flex items-start gap-1") do
              render Views::Frameworks::Explorer::CapabilityNameFrame.new(
                capability: @capability,
                framework_id: @framework_id,
                mode: @mode,
                pending_edit_count: @capability_pending_count,
                pending_edit: @capability_pending_edit,
                search_query: @search_query
              )
              row_actions_kebab if show_row_kebab?
            end
            draft_state_badge if @mode == :edit
            # Capability-anchored clarifications (a cell with no expectation
            # to hang on) glyph the capability row.
            render_clarification_glyph(@capability_data[:clarification_count],
                                       suggestion_id: @capability_data[:clarification_suggestion_id])
            # Description: inline-editable in edit mode (also shown when blank,
            # as an "Add a description…" affordance). View mode renders it only
            # when present.
            if @mode == :edit || @capability.description.present?
              desc_pending = @capability_data[:description_pending_edit]
              render Views::Frameworks::Explorer::CapabilityDescriptionFrame.new(
                capability: @capability,
                framework_id: @framework_id,
                mode: @mode,
                pending_edit: desc_pending,
                pending_edit_count: desc_pending ? 1 : 0,
                search_query: @search_query
              )
            end
          end
        end
      end

      # Level cells
      @merged_levels.each do |level|
        render Views::Frameworks::Explorer::MatrixCell.new(
          cell_data: @cells[level[:ordinal]],
          ordinal: level[:ordinal],
          framework_id: @framework_id,
          mode: @mode,
          search_query: @search_query,
          current_person_id: @current_person_id,
          approval_authority: @approval_authority,
          capability_name: @capability.name
        )
      end
    end
  end

  # Visible only in edit mode. A capability *added* in the draft carries the
  # wiggle on its name (the universal "differs from published" signal — see
  # CapabilityNameFrame), so no "New in draft" pill. A capability staged for
  # *archive* keeps an explicit "Pending archive" badge — removal is a distinct
  # state (the row is also struck through), not just "differs from published".
  def draft_state_badge
    return unless pending_archive?(@capability)

    span(class: "ml-2 inline-flex items-center rounded-full px-2 py-0.5 " \
                "text-[10px] font-semibold bg-amber-100 text-amber-700 " \
                "dark:bg-amber-900/30 dark:text-amber-300") { "Pending archive" }
  end

  # The expanded row ships as a hidden PLACEHOLDER — the matrix controller
  # fetches the real content from `data-expanded-src` (+ the table's shared
  # role/track scope, see Matrix#expanded_row_scope) on first expand. The
  # illustrations for every capability were 81% of the edit-mode payload while
  # the accordion shows one row at a time (framework-explorer.md, Lesson 25).
  def expanded_row
    render Views::Frameworks::Explorer::ExpandedRow.new(
      capability_data: @capability_data,
      merged_levels: @merged_levels,
      framework_id: @framework_id,
      expanded_src: expanded_src,
      loaded: false,
      mode: @mode
    )
  end

  # The mode-specific path for this row's content (edit mode renders the inline
  # editors, ghosts and "+ Add illustration"). Deliberately WITHOUT the role/
  # track query: that rides once on the table, not once per row — at 100 roles ×
  # 150 capabilities a per-row copy is ~700 KB of attribute text.
  def expanded_src
    if @mode == :edit
      edit_expanded_row_framework_path(@framework_id, capability_id: @capability.capability_id)
    else
      expanded_row_framework_path(@framework_id, capability_id: @capability.capability_id)
    end
  end

  # Row-actions kebab — edit mode, the LAST control of the row's hover cluster
  # (pencil · discuss · kebab; framework-explorer.md §11/§12). It gathers every
  # action available on this capability for this viewer: inline Approve / Reject
  # of its pending name / description edits (approval authority — the
  # actionable-feed pattern), the "Edit …" stand-ins for the hover pencils, and
  # Discuss / Move / Edit roles / Archive.
  #
  # Every edit-mode row has at least "Discuss…" (edit mode already carries the
  # suggest rights a clarification needs), so the kebab is unconditional there.
  def show_row_kebab?
    @mode == :edit
  end

  # "Edit roles…" — manage this capability's role bindings. A direct structural
  # edit (add/remove bindings auto-open a draft), so it's on the edit-structure
  # bar like add-capability, not the broader suggest bar.
  def show_binding_action?
    @can_edit_structure
  end

  # Archive is offered to any edit-mode (suggest-rights) viewer and hidden once
  # already staged for archive. The Operation decides — from the edit/suggest
  # toggle + the viewer's authority — whether it applies directly or lands as a
  # pending archive suggestion, so the kebab no longer gates on edit_structure.
  def show_archive_action?
    !pending_archive?(@capability)
  end

  def row_actions_kebab
    render_hover_cluster(
      scope: "row",
      menu: {
        label: "Capability actions",
        kind: "capability",
        **row_menu_data
      }
    )
  end

  # Everything the client-side builder needs to compose this row's menu:
  # approvals the viewer may act on, the neighbours a move targets, and the
  # flags for the two structural items. The capability's id and name come from
  # the `<tr>`; the item labels and paths live in the controller (#380).
  def row_menu_data
    data = { levels: @merged_levels.map { |level| level[:ordinal] }.join(",") }
    if @approval_authority.can_approve?("capability")
      data.merge!(approval_menu_data(@capability_pending_edit, prefix: "name_"))
      data.merge!(approval_menu_data(@description_pending_edit, prefix: "desc_"))
    end
    data[:move] = "1" if show_move_actions?
    data[:bindings] = "1" if show_binding_action?
    if show_archive_action?
      data[:archive] = "1"
      data[:stable] = @capability.stable_id
      data[:mapping] = (!archive_added_in_draft?).to_s
    end
    data
  end

  # "Move up / Move down" — reorder within the category, relative to the movable
  # row the viewer sees in that direction (struck pending-archive rows are
  # skipped; a struck row itself gets no move items). Direct structural edit on
  # the edit-structure bar. Which directions exist is decided client-side from
  # the `data-movable` rows in this category's `<tbody>`, so an in-place move
  # can't leave the menu offering a stale neighbour.
  def show_move_actions?
    @can_edit_structure && !@struck
  end

  def archive_added_in_draft?
    @capability.respond_to?(:added_in_draft) && @capability.added_in_draft
  end
end
