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
                 roles_by_id: {}, current_person_id: nil, search_query: nil, can_archive: false)
    @capability_data = capability_data
    @merged_levels = merged_levels
    @selected_role_ids = selected_role_ids
    @framework_id = framework_id
    @mode = mode
    @roles_by_id = roles_by_id
    @current_person_id = current_person_id
    @search_query = search_query
    @can_archive = can_archive
    @capability = capability_data[:capability]
    @bound = capability_data[:bound_to_selected]
    @cells = capability_data[:cells]
    @capability_pending_count = capability_data[:pending_suggestion_count] || 0
    @capability_pending_edit = capability_data[:pending_edit]
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
            render Views::Frameworks::Explorer::CapabilityNameFrame.new(
              capability: @capability,
              framework_id: @framework_id,
              mode: @mode,
              pending_edit_count: @capability_pending_count,
              pending_edit: @capability_pending_edit,
              search_query: @search_query
            )
            draft_state_badge if @mode == :edit
            p(class: "text-xs text-gray-600 dark:text-gray-300 mt-0.5 line-clamp-1") do
              render_highlighted(@capability.description, @search_query)
            end if @capability.description.present?
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
      class: "hidden",
      data: { matrix_target: "expandedRow", capability_id: @capability.capability_id }
    ) do
      # Sticky column — hosts the edit-mode row-actions kebab (Archive, …).
      td(class: "sticky left-0 z-[2] bg-blue-50/30 dark:bg-blue-900/10 " \
                "border-b border-r border-gray-100 dark:border-gray-800 px-3 py-2 align-top") do
        archive_kebab if show_archive_kebab?
      end

      # Expanded cells with full illustrations
      @merged_levels.each do |level|
        expanded_cell(level[:ordinal])
      end
    end
  end

  # Row-actions kebab — edit mode, edit-rights holders, and only while the
  # capability isn't already staged for archive. Lives in the expanded row so
  # it's revealed only when the user drills into a capability.
  def show_archive_kebab?
    @mode == :edit && @can_archive &&
      !(@capability.respond_to?(:pending_archive) && @capability.pending_archive)
  end

  def archive_kebab
    div(class: "relative inline-block", data: { controller: "dropdown" }) do
      button(
        type: "button",
        class: "inline-flex items-center justify-center w-6 h-6 rounded text-gray-400 " \
               "hover:text-gray-700 dark:hover:text-gray-200 hover:bg-gray-200/60 dark:hover:bg-gray-700/60",
        data: { action: "dropdown#toggle", dropdown_target: "trigger" },
        aria_label: "Capability actions", aria_haspopup: "menu", aria_expanded: "false"
      ) do
        svg(class: "w-4 h-4", fill: "currentColor", viewBox: "0 0 20 20") do |s|
          s.path(d: "M10 6a2 2 0 110-4 2 2 0 010 4zm0 2a2 2 0 100 4 2 2 0 000-4zm0 " \
                    "6a2 2 0 100 4 2 2 0 000-4z")
        end
      end
      div(
        class: "hidden absolute left-0 mt-1 w-44 rounded-md bg-white dark:bg-gray-800 " \
               "shadow-lg ring-1 ring-black/5 dark:ring-white/10 z-20 py-1",
        role: "menu",
        data: { dropdown_target: "menu" }
      ) do
        a(
          href: new_framework_capability_archive_path(@framework_id, @capability.capability_id),
          class: "block px-3 py-1.5 text-sm text-red-700 dark:text-red-300 " \
                 "hover:bg-red-50 dark:hover:bg-red-900/20",
          role: "menuitem",
          # Full-page navigation — must break out of the matrix Turbo Frame,
          # else Turbo looks for a #framework-matrix frame in the archive page
          # and renders "Content missing" (lazy-frame trap).
          data: { turbo_frame: "_top" }
        ) { "Archive capability…" }
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
