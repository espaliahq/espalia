# frozen_string_literal: true

# Single capability row in the matrix.
#
# Renders two <tr> elements:
# 1. Compact row (always visible): capability name + expectation text per level cell
# 2. Expanded row (hidden by default): full illustrations for each cell
#
class Views::Frameworks::Explorer::MatrixRow < Views::Base
  include Views::Frameworks::Explorer::Concerns::SuggestionDecoration
  include Views::Frameworks::Explorer::Concerns::SearchHighlight

  # @param capability_data [Hash] from MatrixDataBuilder
  # @param merged_levels [Array<Hash>]
  # @param selected_role_ids [Array<String>]
  # @param framework_id [String] UUID of the framework (for illustration PATCH URLs)
  # @param mode [Symbol] :view or :edit
  # @param roles_by_id [Hash] { role_id => Role } — reused in expanded cells so they
  #   don't each fire a `FrameworkState::Role.find_by` query
  def initialize(capability_data:, merged_levels:, selected_role_ids:, framework_id:, mode: :view,
                 roles_by_id: {}, current_person_id: nil, search_query: nil, can_edit_structure: false,
                 approval_authority: Frameworks::SuggestionApprovalAuthority.none)
    @capability_data = capability_data
    @merged_levels = merged_levels
    @selected_role_ids = selected_role_ids
    @framework_id = framework_id
    @mode = mode
    @roles_by_id = roles_by_id
    @current_person_id = current_person_id
    @search_query = search_query
    @can_edit_structure = can_edit_structure
    @approval_authority = approval_authority
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
          search_query: @search_query
        )
      end
    end
  end

  # Visible only in edit mode — signals that the capability is new in the
  # current draft ("New") or staged for archive ("Pending archive"). View
  # mode filters these entities entirely, so the badges never render there.
  def draft_state_badge
    return unless @capability.respond_to?(:added_in_draft)

    if @capability.added_in_draft
      span(class: "ml-2 inline-flex items-center rounded-full px-2 py-0.5 " \
                  "text-[10px] font-semibold bg-emerald-100 text-emerald-700 " \
                  "dark:bg-emerald-900/30 dark:text-emerald-300") { "New in draft" }
    elsif @capability.respond_to?(:pending_archive) && @capability.pending_archive
      span(class: "ml-2 inline-flex items-center rounded-full px-2 py-0.5 " \
                  "text-[10px] font-semibold bg-amber-100 text-amber-700 " \
                  "dark:bg-amber-900/30 dark:text-amber-300") { "Pending archive" }
    end
  end

  def expanded_row
    tr(
      class: "hidden #{strikethrough_classes}",
      data: { matrix_target: "expandedRow", capability_id: @capability.capability_id }
    ) do
      # Empty sticky column (row-actions kebab lives in the compact row, by
      # the capability name).
      td(class: "sticky left-0 z-[2] bg-blue-50/30 dark:bg-blue-900/10 " \
                "border-b border-r border-gray-100 dark:border-gray-800") { }

      # Expanded cells with full illustrations
      @merged_levels.each do |level|
        expanded_cell(level[:ordinal])
      end
    end
  end

  # Row-actions kebab — edit mode, hover-revealed next to the capability-name
  # pencil. A dropdown menu (Kit::Dropdown) gathering the actions available on
  # this capability for this viewer: inline Approve / Reject of its pending
  # name / description edits (approval authority — the actionable-feed pattern,
  # framework-explorer.md §12), plus Archive (edit-structure rights). The kebab
  # renders only when at least one action applies.
  #
  # toggleRow ignores clicks inside `[data-controller~='dropdown']`, so opening
  # the menu never also expands the row.
  def show_row_kebab?
    @mode == :edit && (show_archive_action? || capability_edit_actions.any?)
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
      dd.trigger(label: "Capability actions") do
        span(
          class: "opacity-0 group-hover:opacity-100 focus-visible:opacity-100 transition-opacity " \
                 "inline-flex items-center justify-center w-5 h-5 rounded shrink-0 " \
                 "text-gray-400 hover:text-primary"
        ) do
          svg(class: "w-4 h-4", fill: "currentColor", viewBox: "0 0 20 20") do |s|
            s.path(d: "M10 6a2 2 0 110-4 2 2 0 010 4zm0 2a2 2 0 100 4 2 2 0 000-4zm0 " \
                      "6a2 2 0 100 4 2 2 0 000-4z")
          end
        end
      end
      dd.menu do
        capability_edit_actions.each { |action| kebab_edit_items(action) }
        kebab_archive_item if show_archive_action?
      end
    end
  end

  # Approve (inline POST) + Reject (shared modal) for one pending field edit.
  # Reuses the actionable-feed machinery: suggestion_action#approve and the
  # reject-suggestion modal, both flagged inline=1 so the controller answers 204
  # and `suggestion:resolved` refreshes the matrix.
  def kebab_edit_items(action)
    button(
      type: "button", role: "menuitem", class: kebab_item_classes("text-green-700 dark:text-green-400"),
      data: {
        controller: "suggestion-action",
        suggestion_action_approve_url_value:
          approve_framework_suggestion_path(@framework_id, action[:suggestion_id], inline: 1),
        action: "suggestion-action#approve"
      }
    ) { "Approve #{action[:field_label]} change" }

    button(
      type: "button", role: "menuitem", class: kebab_item_classes("text-gray-700 dark:text-gray-200"),
      data: {
        action: "click->modal#open",
        modal_target_id: "reject-suggestion-modal",
        reject_suggestion_id: action[:suggestion_id],
        reject_framework_id: @framework_id,
        reject_entity_label: "capability #{action[:field_label]}",
        reject_preview: action[:preview]
      }
    ) { "Reject #{action[:field_label]} change" }
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

  def kebab_item_classes(tone)
    "block w-full text-left px-4 py-2 text-sm #{tone} " \
      "hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors cursor-pointer"
  end

  def archive_added_in_draft?
    @capability.respond_to?(:added_in_draft) && @capability.added_in_draft
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
      ill_pending_edit_details = cell_data[:illustration_pending_edit_details] || {}
      pending_creates = cell_data[:pending_illustration_creates] || []

      cell_data[:bound_selected_role_ids].each do |role_id|
        role = @roles_by_id[role_id]
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
                pending_edit_count: ill_pending_edits[ill.illustration_id] || 0,
                pending_edit: ill_pending_edit_details[ill.illustration_id],
                mode: @mode
              )
            end
            role_pending_creates.each do |suggestion|
              render Views::Frameworks::Explorer::PendingIllustrationFrame.new(
                suggestion: suggestion,
                framework_id: @framework_id,
                is_author: suggestion.author_id.to_s == @current_person_id.to_s
              )
            end
          end
          if @mode == :edit
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
end
