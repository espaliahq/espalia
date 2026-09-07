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
  include Views::Frameworks::Explorer::Concerns::ApprovalKebabItems
  include Views::Frameworks::Explorer::Concerns::DiscussTrigger

  # @param capability_data [Hash] from MatrixDataBuilder
  # @param merged_levels [Array<Hash>]
  # @param selected_role_ids [Array<String>]
  # @param framework_id [String] UUID of the framework (for illustration PATCH URLs)
  # @param mode [Symbol] :view or :edit
  # @param roles_by_id [Hash] { role_id => Role } — reused in expanded cells so they
  #   don't each fire a `FrameworkState::Role.find_by` query
  # @param prev_capability_id [String, nil] the movable row above (for "Move up")
  # @param next_capability_id [String, nil] the movable row below (for "Move down")
  # @param track_filter [String] "ic" / "management" / "both" — rides on the
  #   expanded row's fetch URL so the lazily loaded illustrations match the
  #   role scope the compact row was rendered for
  def initialize(capability_data:, merged_levels:, selected_role_ids:, framework_id:, mode: :view,
                 roles_by_id: {}, current_person_id: nil, search_query: nil, can_edit_structure: false,
                 approval_authority: Frameworks::SuggestionApprovalAuthority.none,
                 prev_capability_id: nil, next_capability_id: nil, track_filter: "both")
    @capability_data = capability_data
    @merged_levels = merged_levels
    @selected_role_ids = selected_role_ids
    @track_filter = track_filter
    @framework_id = framework_id
    @mode = mode
    @roles_by_id = roles_by_id
    @current_person_id = current_person_id
    @search_query = search_query
    @can_edit_structure = can_edit_structure
    @approval_authority = approval_authority
    @prev_capability_id = prev_capability_id
    @next_capability_id = next_capability_id
    @capability = capability_data[:capability]
    @bound = capability_data[:bound_to_selected]
    @cells = capability_data[:cells]
    @capability_pending_count = capability_data[:pending_suggestion_count] || 0
    @capability_pending_edit = capability_data[:pending_edit]
    @description_pending_edit = capability_data[:description_pending_edit]
    # Struck through (edit mode only) when the capability is staged for archive
    # in the open draft — the "going away on publish" affordance. Still carries
    # the "Pending archive" badge for the explicit label.
    @struck = @mode == :edit && @capability.respond_to?(:pending_archive) && @capability.pending_archive
  end

  def view_template
    compact_row
    expanded_row
  end

  private

  # Red line-through across the whole row when the capability is staged for
  # archive. Applied to each cell (`[&>td]`) rather than the <tr>, because
  # text-decoration doesn't reliably propagate from a table-row to its cells.
  STRIKETHROUGH_CLASSES = "[&>td]:line-through [&>td]:decoration-red-400 [&>td]:decoration-2"

  def strikethrough_classes
    @struck ? STRIKETHROUGH_CLASSES : ""
  end

  def compact_row
    tr(
      class: "#{@bound ? '' : 'opacity-50'} #{strikethrough_classes} group cursor-pointer scroll-mt-20 " \
             "hover:bg-gray-50 dark:hover:bg-gray-800/50 transition-colors",
      data: {
        action: "click->matrix#toggleRow",
        matrix_target: "row",
        capability_id: @capability.capability_id
      }
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
          svg(
            class: "w-3 h-3 mt-1 text-gray-400 transition-transform shrink-0",
            data: { matrix_target: "rowChevron" },
            fill: "none", viewBox: "0 0 24 24", stroke: "currentColor", stroke_width: "2"
          ) do |s|
            s.path(d: "M9 5l7 7-7 7")
          end

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
    return unless @capability.respond_to?(:pending_archive) && @capability.pending_archive

    span(class: "ml-2 inline-flex items-center rounded-full px-2 py-0.5 " \
                "text-[10px] font-semibold bg-amber-100 text-amber-700 " \
                "dark:bg-amber-900/30 dark:text-amber-300") { "Pending archive" }
  end

  # The expanded row ships as a hidden PLACEHOLDER — the matrix controller
  # fetches the real content from `data-expanded-src` on first expand. The
  # illustrations for every capability were 81% of the edit-mode payload while
  # the accordion shows one row at a time (framework-explorer.md, lazy-row
  # lesson).
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

  # The fetch URL for this row's content — mode-specific (edit mode renders the
  # inline editors, ghosts and "+ Add illustration"), carrying the role/track
  # scope the compact row was rendered under. Defaults (all roles, both
  # tracks) are omitted so the URL stays short.
  def expanded_src
    params = {}
    params[:roles] = @selected_role_ids if @selected_role_ids.present?
    params[:track] = @track_filter if @track_filter.present? && @track_filter != "both"

    if @mode == :edit
      edit_expanded_row_framework_path(@framework_id, capability_id: @capability.capability_id, **params)
    else
      expanded_row_framework_path(@framework_id, capability_id: @capability.capability_id, **params)
    end
  end

  # Row-actions kebab — edit mode, hover-revealed next to the capability-name
  # pencil. A dropdown menu (Kit::Dropdown) gathering the actions available on
  # this capability for this viewer: inline Approve / Reject of its pending
  # name / description edits (approval authority — the actionable-feed pattern,
  # framework-explorer.md §12), plus Archive (any suggest-rights viewer — the
  # Operation decides direct-vs-suggestion). The kebab renders only when at least
  # one action applies.
  #
  # toggleRow ignores clicks inside `[data-controller~='dropdown']`, so opening
  # the menu never also expands the row.
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
    !(@capability.respond_to?(:pending_archive) && @capability.pending_archive)
  end

  # Pending name / description edits the viewer may approve, as
  # { field_label:, suggestion_id:, preview: }. Both are tier-2 ("capability").
  def capability_edit_actions
    return [] unless @approval_authority.can_approve?("capability")

    [
      edit_action("name", @capability_pending_edit),
      edit_action("description", @description_pending_edit)
    ].compact
  end

  def edit_action(field_label, descriptor)
    return nil unless descriptor && descriptor[:suggestion_id]

    { field_label: field_label,
      suggestion_id: descriptor[:suggestion_id],
      preview: descriptor[:suggested_value].to_s }
  end

  def row_actions_kebab
    render Components::Kit::Dropdown.new(align: :left) do |dd|
      kebab_trigger(dd, label: "Capability actions",
        reveal_classes: "opacity-0 group-hover:opacity-100 group-focus-within:opacity-100")
      dd.menu do
        capability_edit_actions.each { |action| kebab_edit_items(action) }
        kebab_discuss_item
        kebab_move_items if show_move_actions?
        kebab_binding_item if show_binding_action?
        kebab_archive_item if show_archive_action?
      end
    end
  end

  # "Discuss…" — ask about the capability. Unlike the cell trigger it names no
  # level, so the modal offers this row's levels (plus "the capability as a
  # whole") rather than assuming one.
  def kebab_discuss_item
    render_discuss_menu_item(
      capability_id: @capability.capability_id,
      context_label: @capability.name,
      level_options: @merged_levels.map { |level| { ordinal: level[:ordinal], label: "L#{level[:ordinal]}" } }
    )
  end

  # Approve (inline POST) + Reject (shared modal) for one pending field edit —
  # the shared §12 kebab machinery (ApprovalKebabItems).
  def kebab_edit_items(action)
    render_approval_kebab_items(
      framework_id: @framework_id,
      suggestion_id: action[:suggestion_id],
      change_label: "#{action[:field_label]} change",
      entity_label: "capability #{action[:field_label]}",
      preview: action[:preview]
    )
  end

  # "Move up / Move down" — reorder within the category, relative to the
  # movable row the viewer sees in that direction (struck pending-archive rows
  # are skipped; a struck row itself gets no move items). Direct structural
  # edit on the edit-structure bar. Each item POSTs via reorder-move and, on
  # 204, dispatches org-structure:updated → matrix#refresh — fresh neighbour
  # ids every render, like the category header chevrons.
  def show_move_actions?
    @can_edit_structure && !@struck && (@prev_capability_id || @next_capability_id)
  end

  def kebab_move_items
    kebab_move_item("Move up", @prev_capability_id, "before") if @prev_capability_id
    kebab_move_item("Move down", @next_capability_id, "after") if @next_capability_id
  end

  def kebab_move_item(label, target_id, placement)
    button(
      type: "button", role: "menuitem", class: kebab_item_classes("text-gray-700 dark:text-gray-200"),
      data: {
        controller: "reorder-move",
        reorder_move_url_value: framework_capability_reorders_path(framework_id: @framework_id),
        reorder_move_body_value: {
          reorder: { capability_id: @capability.capability_id, target_id: target_id, placement: placement }
        }.to_json,
        action: "reorder-move#move"
      }
    ) { label }
  end

  def kebab_binding_item
    button(
      type: "button", role: "menuitem", class: kebab_item_classes("text-gray-700 dark:text-gray-200"),
      data: {
        action: "click->modal#open",
        modal_target_id: "binding-editor-modal",
        binding_editor_capability_id: @capability.capability_id,
        binding_editor_capability_name: @capability.name
      }
    ) { "Edit roles…" }
  end

  def kebab_archive_item
    button(
      type: "button", role: "menuitem", class: kebab_item_classes("text-gray-700 dark:text-gray-200"),
      data: {
        action: "click->modal#open",
        modal_target_id: "archive-capability-modal",
        archive_capability_id: @capability.capability_id,
        archive_capability_name: @capability.name,
        archive_stable_id: @capability.stable_id,
        archive_needs_mapping: (!archive_added_in_draft?).to_s
      }
    ) { "Archive…" }
  end

  def archive_added_in_draft?
    @capability.respond_to?(:added_in_draft) && @capability.added_in_draft
  end
end
