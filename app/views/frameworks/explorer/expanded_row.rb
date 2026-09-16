# frozen_string_literal: true

# The expanded row under a capability — one `<tr>` holding, per level column,
# the illustrations for each selected bound role (plus the pending ghosts and
# the "+ Add example" affordance in edit mode).
#
# Rendered in two states:
#
# - **Placeholder** (`loaded: false`) — what the matrix ships for every
#   capability. A hidden `<tr>` carrying the accordion's target/data attributes
#   and one loading cell; no illustration content. The matrix controller
#   fetches the real row from `data-expanded-src` the first time the row is
#   expanded and swaps this `<tr>` for the loaded one.
# - **Loaded** (`loaded: true`) — the response of
#   {FrameworksController#expanded_row} / `#edit_expanded_row`: the same
#   `<tr>` with the per-level cells.
#
# Why on demand: the expanded rows were 81% of the edit-mode matrix payload
# (6.2 of 7.6 MB on the real me&u framework — 850 illustration frames, 1,131
# "+ Add example" frames, each with its own form and Stimulus mount) even
# though the accordion only ever shows one at a time. See
# docs/guidelines/framework-explorer.md, Hard-Won Lesson 23 and the lazy-row
# lesson that follows it.
#
class Views::Frameworks::Explorer::ExpandedRow < Views::Base
  include Views::Frameworks::Explorer::Concerns::StickyColumn
  include Views::Frameworks::Explorer::Concerns::PendingArchive

  # @param capability_data [Hash] from MatrixDataBuilder
  # @param merged_levels [Array<Hash>]
  # @param framework_id [String]
  # @param loaded [Boolean] placeholder (false) or full content (true)
  # @param expanded_src [String, nil] the placeholder's fetch path (the matrix
  #   controller appends the table's role/track scope); unused once loaded
  # @param mode [Symbol] :view or :edit
  # @param roles_by_id [Hash] { role_id => Role }
  # @param current_person_id [String, nil]
  # @param can_edit_structure [Boolean]
  # @param approval_authority [Frameworks::SuggestionApprovalAuthority]
  def initialize(capability_data:, merged_levels:, framework_id:, loaded:, expanded_src: nil, mode: :view,
                 roles_by_id: {}, current_person_id: nil, can_edit_structure: false,
                 approval_authority: Frameworks::SuggestionApprovalAuthority.none)
    @capability_data = capability_data
    @merged_levels = merged_levels
    @framework_id = framework_id
    @expanded_src = expanded_src
    @loaded = loaded
    @mode = mode
    @roles_by_id = roles_by_id
    @current_person_id = current_person_id
    @can_edit_structure = can_edit_structure
    @approval_authority = approval_authority
    @capability = capability_data[:capability]
    @cells = capability_data[:cells]
  end

  def view_template
    tr(
      id: "expanded-row-#{@capability.capability_id}",
      # Always shipped hidden — the controller un-hides it when the row is (still)
      # the expanded one, so a loaded row can't flash open under a collapsed row.
      class: "hidden #{strikethrough_classes}",
      data: {
        matrix_target: "expandedRow",
        capability_id: @capability.capability_id,
        expanded_src: @expanded_src,
        loaded: @loaded.to_s
      }.compact
    ) do
      gutter_cell
      if @loaded
        @merged_levels.each { |level| expanded_cell(level[:ordinal]) }
      else
        placeholder_cell
      end
    end
  end

  private

  # Only the loaded content is struck for a pending-archive capability — the
  # placeholder's loading line and its error/Retry must never read as deleted
  # text.
  def strikethrough_classes
    @loaded && struck?(@capability, @mode) ? STRIKETHROUGH_CLASSES : ""
  end

  # Empty sticky column (row-actions kebab lives in the compact row, by the
  # capability name).
  #
  # OPAQUE equivalents of the expanded row's tint, not the tint itself:
  # #fafcff is blue-50/30 over white and #111b31 is blue-900/10 over
  # gray-900, so this cell matches its neighbouring expanded cells while
  # actually masking what scrolls beneath it. As `bg-blue-50/30
  # dark:bg-blue-900/10` it was translucent, and a whole column of
  # illustration text rendered through it (issue #371).
  def gutter_cell
    td(class: "sticky left-0 z-[2] bg-[#fafcff] dark:bg-[#111b31] " \
              "#{STICKY_EDGE_CLASSES} mx-exp-gutter") { }
  end

  # One cell spanning every level column: the loading line, and the shared
  # (hidden) load-failure block the controller reveals when the fetch fails —
  # the same `Kit::FrameLoadError` the lazy frames use, with the matrix's own
  # Retry action since no `frame-error` controller is involved.
  def placeholder_cell
    td(
      colspan: [ @merged_levels.size, 1 ].max,
      class: "mx-exp-placeholder"
    ) do
      p(class: "text-gray-600 dark:text-gray-300", data: { expanded_row_state: "loading" }) do
        "Loading examples…"
      end
      render Components::Kit::FrameLoadError.new(
        id: "expanded-row-error-#{@capability.capability_id}",
        subject: "the examples for this capability",
        classes: "space-y-2",
        retry_action: "matrix#retryExpandedRow"
      )
    end
  end

  def expanded_cell(ordinal) # rubocop:disable Metrics/MethodLength
    cell_data = @cells[ordinal]

    # An authorable placeholder (empty-but-applicable cell) has no expectation,
    # so there are no illustrations to show — render the blank expanded td.
    if cell_data.nil? || cell_data[:expectation].nil? || cell_data[:bound_selected_role_ids].blank?
      td(class: "mx-exp-cell") { }
      return
    end

    expectation = cell_data[:expectation]

    td(
      class: "mx-exp-cell mx-exp-cell--focusable",
      data: {
        action: "click->matrix#focusCell",
        capability_id: @capability.capability_id,
        level_ordinal: ordinal,
        expectation_id: expectation.expectation_id
      }
    ) do
      ill_pending_edits = cell_data[:illustration_pending_edits] || {}
      ill_pending_edit_details = cell_data[:illustration_pending_edit_details] || {}
      ill_clarifications = cell_data[:illustration_clarifications] || {}
      pending_creates = cell_data[:pending_illustration_creates] || []

      cell_data[:bound_selected_role_ids].each do |role_id|
        role = @roles_by_id[role_id]
        next unless role

        illustrations = cell_data[:illustrations_by_role][role_id] || []
        role_pending_creates = pending_creates.select { |s| s.proposed_attributes["role_id"] == role_id }

        div(class: "mb-2 last:mb-0") do
          render Components::Kit::Badge.new(role.code, variant: :default)
          ul_attrs = {
            id: "illustrations-#{expectation.expectation_id}-#{role_id}",
            class: "mt-1 space-y-1.5"
          }
          # ↑/↓ reordering — edit-rights holders only, and only when there is
          # something to reorder. The controller moves the DOM node on a 204,
          # so the expanded row never collapses (no matrix refresh).
          can_reorder = @mode == :edit && @can_edit_structure && illustrations.size > 1
          if can_reorder
            ul_attrs[:data] = {
              controller: "reorder-list",
              reorder_list_url_value:
                framework_illustration_reorders_path(framework_id: @framework_id),
              reorder_list_param_name_value: "illustration_id"
            }
          end
          ul(**ul_attrs) do
            illustrations.each do |ill|
              render Views::Frameworks::Explorer::IllustrationFrame.new(
                illustration: ill,
                framework_id: @framework_id,
                pending_edit_count: ill_pending_edits[ill.illustration_id] || 0,
                pending_edit: ill_pending_edit_details[ill.illustration_id],
                mode: @mode,
                can_reorder: can_reorder,
                approval_authority: @approval_authority,
                discuss_context_label: "#{@capability.name} · L#{ordinal} · #{role.name} example",
                clarification: ill_clarifications[ill.illustration_id]
              )
            end
            role_pending_creates.each do |suggestion|
              render Views::Frameworks::Explorer::PendingIllustrationFrame.new(
                suggestion: suggestion,
                framework_id: @framework_id,
                is_author: suggestion.author_id.to_s == @current_person_id.to_s,
                approval_authority: @approval_authority
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
