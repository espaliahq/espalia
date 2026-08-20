# frozen_string_literal: true

# Single cell in the capability × level matrix.
#
# Shows the behavioural expectation text and an illustration indicator.
# Illustrations are shown in the expanded row (managed by MatrixRow),
# not inline in the cell.
#
class Views::Frameworks::Explorer::MatrixCell < Views::Base
  include Views::Frameworks::Explorer::Concerns::SuggestionDecoration
  include Views::Frameworks::Explorer::Concerns::ApprovalKebabItems

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
  def initialize(cell_data:, ordinal:, framework_id: nil, mode: :view, search_query: nil,
                 current_person_id: nil,
                 approval_authority: Frameworks::SuggestionApprovalAuthority.none)
    @cell_data = cell_data
    @ordinal = ordinal
    @framework_id = framework_id
    @mode = mode
    @search_query = search_query
    @current_person_id = current_person_id
    @approval_authority = approval_authority
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
    td(class: "group/cell px-2 py-1.5 border-b border-r border-gray-100 dark:border-gray-800 " \
              "bg-gray-50/40 dark:bg-gray-800/20 align-top") do
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
      is_author: @current_person_id.present? && suggestion.author_id.to_s == @current_person_id.to_s
    )
  end

  def empty_cell
    td(class: "px-3 py-2.5 text-center border-b border-r border-gray-100 dark:border-gray-800 " \
              "bg-gray-50/50 dark:bg-gray-800/20 align-top") do
      span(class: "text-gray-300 dark:text-gray-600") { "\u2014" }
    end
  end

  def filled_cell
    td(class: "px-3 py-2.5 border-b border-r border-gray-100 dark:border-gray-800 align-top") do
      if approvable_pending_edit?
        div(class: "flex items-start gap-1") do
          div(class: "min-w-0 flex-1") { expectation_text }
          expectation_approval_kebab
        end
      else
        expectation_text
      end
      # Open clarification discussion on this expectation — content glyph,
      # never the pending-change vocabulary (nothing is proposed).
      render_clarification_glyph(@cell_data[:clarification_count])
      illustration_indicator if @cell_data[:illustration_count] > 0
    end
  end

  # The expectation's pending edit is approvable from the grid when the viewer
  # clears the expectation tier — same §12 machinery as the row kebab. Rendered
  # OUTSIDE ExpectationTextFrame so the inline-edit frame swap can't drop it.
  def approvable_pending_edit?
    @mode == :edit &&
      @cell_data[:pending_edit].present? &&
      @cell_data[:pending_edit][:suggestion_id].present? &&
      @approval_authority.can_approve?("behavioural_expectation")
  end

  def expectation_approval_kebab
    render_approval_kebab(
      framework_id: @framework_id,
      suggestion_id: @cell_data[:pending_edit][:suggestion_id],
      change_label: "expectation change",
      entity_label: "expectation",
      preview: @cell_data[:pending_edit][:suggested_value].to_s,
      trigger_label: "Expectation suggestion actions",
      reveal_classes: "opacity-0 group-hover:opacity-100 focus-visible:opacity-100"
    )
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
    div(class: "mt-1.5 flex items-center gap-1") do
      span(class: "w-1.5 h-1.5 rounded-full bg-primary") { }
      span(class: "text-[10px] text-gray-600 dark:text-gray-300") do
        count = @cell_data[:illustration_count]
        "#{count} #{'example'.pluralize(count)}"
      end
    end
  end
end
