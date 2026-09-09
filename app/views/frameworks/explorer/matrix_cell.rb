# frozen_string_literal: true

# Single cell in the capability × level matrix.
#
# Shows the behavioural expectation text and an illustration indicator.
# Illustrations are shown in the expanded row (managed by MatrixRow),
# not inline in the cell.
#
class Views::Frameworks::Explorer::MatrixCell < Views::Base
  include Views::Frameworks::Explorer::Concerns::SuggestionDecoration
  include Views::Frameworks::Explorer::Concerns::HoverCluster
  include Views::Frameworks::Explorer::Concerns::MenuItems
  include Views::Frameworks::Explorer::Concerns::DiscussTrigger

  # Turbo Stream anchor for one capability × level cell. Authoring an
  # expectation replaces exactly this `<td>` — no matrix refresh.
  #
  # @param capability_id [String]
  # @param ordinal [Integer]
  # @return [String]
  def self.cell_id(capability_id, ordinal) = "cell-#{capability_id}-#{ordinal}"

  # @param cell_data [Hash, nil] from MatrixDataBuilder — nil for empty cells
  # @param ordinal [Integer] the level ordinal for this column
  # @param framework_id [String] UUID — required when mode is :edit for the expectation edit URL
  # @param mode [Symbol] :view or :edit
  # @param search_query [String, nil] active text filter — highlighted in the
  #   expectation text
  # @param current_person_id [String, nil] the viewer's person id — marks their
  #   own pending proposal as amendable vs others' as "suggest alternative"
  # @param approval_authority [Frameworks::SuggestionApprovalAuthority] per-viewer
  #   authority — gates the expectation-edit approve/reject kebab (§12)
  # @param capability_name [String, nil] names the cell in the "Discuss…" modal
  #   ("Strategic Thinking · L5") — the cell data carries no capability name
  def initialize(cell_data:, ordinal:, framework_id: nil, mode: :view, search_query: nil,
                 current_person_id: nil,
                 approval_authority: Frameworks::SuggestionApprovalAuthority.none,
                 capability_name: nil)
    @cell_data = cell_data
    @ordinal = ordinal
    @framework_id = framework_id
    @mode = mode
    @search_query = search_query
    @current_person_id = current_person_id
    @approval_authority = approval_authority
    @capability_name = capability_name
  end

  def view_template
    if @cell_data && @cell_data[:expectation]
      filled_cell
    elsif authorable?
      authorable_cell
    else
      empty_cell
    end
  end

  private

  # The cell's Turbo Stream id — stable across the empty → filled transition
  # authoring an expectation makes, so the create response can replace exactly
  # this cell. nil for a not-applicable cell (no cell data, nothing to address).
  #
  # @return [String, nil]
  def cell_id
    capability_id = @cell_data && @cell_data[:capability_id]
    capability_id && self.class.cell_id(capability_id, @ordinal)
  end

  # An empty-but-applicable cell the viewer may author into. Offered to any
  # edit-mode viewer (edit mode already requires suggest rights) — the
  # Operation's suggest/approve path applies it directly for an authority-holder
  # or proposes it as a suggestion otherwise. The builder only emits the
  # `authorable` placeholder in edit mode for cells bound to a selected role with
  # a level at this ordinal.
  def authorable?
    @mode == :edit && @cell_data && @cell_data[:authorable]
  end

  # Empty cell. An expectation is singular per cell, so once a proposal exists we
  # show its editable ghost(s) (pencil → amend) and NOT a "+ Add expectation"
  # affordance — amending the existing proposal is the way to change it, like
  # every other suggestion flow. With no proposal yet, show "+ Add expectation".
  def authorable_cell
    td(id: cell_id,
       class: "px-2 py-1.5 border-b border-r border-gray-100 dark:border-gray-800 " \
              "bg-gray-50/40 dark:bg-gray-800/20 align-top",
       data: hover_cluster_data("cell")) do
      creates = @cell_data[:pending_expectation_creates] || []
      if creates.any?
        creates.each { |suggestion| render_pending_ghost(suggestion) }
      else
        render Views::Frameworks::Explorer::NewExpectationFrame.new(
          capability_id: @cell_data[:capability_id],
          level_ordinal: @ordinal,
          framework_id: @framework_id
        )
      end
    end
  end

  def render_pending_ghost(suggestion)
    render Views::Frameworks::Explorer::PendingExpectationFrame.new(
      suggestion: suggestion,
      framework_id: @framework_id,
      level_ordinal: @ordinal,
      is_author: @current_person_id.present? && suggestion.author_id.to_s == @current_person_id.to_s,
      approval_authority: @approval_authority
    )
  end

  # `cell_id` is nil for a genuinely not-applicable cell (no cell data at all),
  # and Phlex omits a nil attribute — so this stays addressable whenever there
  # is anything to address.
  def empty_cell
    td(id: cell_id, class: "mx-cell mx-cell-empty") do
      span(class: "text-gray-300 dark:text-gray-600") { "\u2014" }
    end
  end

  # A focusable cell carries its level ordinal + expectation id so feed
  # navigation can settle cell focus from the compact row synchronously — the
  # expanded row is fetched on demand and may not be in the DOM yet (Hard-Won
  # Lesson 25). Same contract as the expanded cell: an expectation AND a
  # selected bound role; an empty or not-applicable cell is not a focus target.
  def filled_cell
    td(id: cell_id, class: "mx-cell",
       data: cell_cluster_data.merge(focus_target_data)) do
      # One layout for both states — the kebab is conditional, the wrapper is
      # not, so the pending-edit cell can't drift from the plain cell. No
      # flex-1 on the text: the kebab sits right after it, not at the far edge
      # of the cell (phlex-views.md, pencil-placement rule).
      div(class: "mx-line") do
        div { expectation_text }
        # pencil · discuss · kebab — the pencil is rendered by
        # ExpectationTextFrame above (it has to travel with the frame), the rest
        # here (framework-explorer.md §11, HoverCluster).
        expectation_hover_cluster if @mode == :edit
      end
      # Open clarification discussion on this expectation — content glyph,
      # never the pending-change vocabulary (nothing is proposed).
      render_clarification_glyph(@cell_data[:clarification_count],
                                 suggestion_id: @cell_data[:clarification_suggestion_id])
      illustration_indicator if @cell_data[:illustration_count] > 0
    end
  end

  # View mode has no hover controls to reveal, so it ships no cluster attribute.
  def cell_cluster_data
    @mode == :edit ? hover_cluster_data("cell") : {}
  end

  def focus_target_data
    return {} if @cell_data[:bound_selected_role_ids].blank?

    { level_ordinal: @ordinal, expectation_id: @cell_data[:expectation].expectation_id }
  end

  # The cell's hover cluster: the Discuss bubble plus the ⋮ that carries every
  # cell action as a menu item — including "Edit expectation…", because on a
  # coarse pointer the cluster collapses to the kebab alone. Offered to every
  # edit-mode viewer (edit mode already requires suggest rights).
  def expectation_hover_cluster
    render_hover_cluster(
      scope: "cell",
      discuss: {
        label: "Discuss this expectation",
        capability_id: @cell_data[:expectation].capability_id,
        level_ordinal: @ordinal,
        context_label: cell_context_label
      },
      menu: { label: "Expectation actions", kind: "expectation", **cell_menu_data }
    )
  end

  # Only the ids the client-side builder can't read off the grid. The
  # capability's name (the Discuss context label) comes from the `<tr>`.
  def cell_menu_data
    data = { expectation: @cell_data[:expectation].expectation_id, level: @ordinal }
    data.merge!(approval_menu_data(@cell_data[:pending_edit])) if approvable_pending_edit?
    data
  end

  def cell_context_label
    [ @capability_name, "L#{@ordinal}" ].compact.join(" \u00b7 ")
  end

  # The expectation's pending edit is approvable from the grid when the viewer
  # clears the expectation tier — same §12 machinery as the row kebab. The kebab
  # is rendered OUTSIDE ExpectationTextFrame so the inline-edit frame swap can't
  # drop it (the trade-off: a pending edit landed via the swap gets its
  # Approve/Reject items on the next matrix render — the squiggle click's card
  # covers the interim).
  def approvable_pending_edit?
    @mode == :edit &&
      @cell_data[:pending_edit].present? &&
      @cell_data[:pending_edit][:suggestion_id].present? &&
      @approval_authority.can_approve?("behavioural_expectation")
  end

  def expectation_text
    pending_count = @cell_data[:pending_suggestion_count] || 0
    expectation = @cell_data[:expectation]

    # A draft-added expectation carries the wiggle (rendered by the frame) — the
    # universal "differs from published" signal — not a separate "New in draft" pill.
    render Views::Frameworks::Explorer::ExpectationTextFrame.new(
      expectation: expectation,
      framework_id: @framework_id,
      mode: @mode,
      pending_edit_count: pending_count,
      pending_edit: @cell_data[:pending_edit],
      search_query: @search_query
    )

    if pending_count >= 2
      render Views::Frameworks::Suggestions::InlineIndicator.new(count: pending_count)
    end
  end

  def illustration_indicator
    div(class: "mx-examples") do
      span(class: "mx-dot") { }
      span(class: "mx-count") do
        count = @cell_data[:illustration_count]
        "#{count} #{'example'.pluralize(count)}"
      end
    end
  end
end
