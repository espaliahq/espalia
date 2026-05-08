# frozen_string_literal: true

# Unified capability row in the assessment matrix.
#
# Renders two <tr> elements:
# 1. Compact row (always visible): capability name + one AssessmentCell per level
# 2. Expanded row (hidden by default): read-only illustrations for each cell
#
class Views::Assessments::AssessmentRow < Views::Base
  # @param capability_data [Hash] from MatrixDataBuilder
  # @param merged_levels [Array<Hash>]
  # @param person_level [Integer]
  # @param assessment_id [String]
  # @param context [Symbol] :self, :manager, or :alignment
  # @param blocked [Boolean]
  # @param block_reason [String, nil]
  # @param contribution [Float, nil] perspective-specific contribution (falls back to effective from capability_data)
  # @param secondary_contributions [Array<Array(String, Float)>] [["Mgr", -0.5], ...]
  # @param expanded [Boolean] whether this row should be pre-expanded (URL-driven)
  # @param focused_level_ordinal [Integer, nil] level ordinal that should arrive
  #   already focused (cell-level deep link). Stamped on the expanded `<tr>` so
  #   matrix_controller#dispatchInitialFocus can resurface it.
  # @param category_id [String, nil] active category for tab preservation on rating
  # @param frozen [Boolean] when true and context is :self/:manager, cells render
  #   primary frequency read-only (alignment in progress)
  # @param alignment_locked [Boolean] when true and context is :alignment, cells render
  #   primary frequency read-only (alignment completed)
  # @param viewer_person_id [String, nil] UUID of the current viewer; nil hides
  #   the evidence section entirely.
  # @param can_create_evidence [Boolean] whether to render the "+ Add evidence"
  #   affordance. Independent of `frozen`/`alignment_locked` — evidence is not
  #   frozen during alignment.
  # @param can_relink_others_evidence [Boolean] whether the viewer is the
  #   assessee or in their manager chain — gates the Relink kebab option for
  #   evidence the viewer didn't author.
  def initialize(capability_data:, merged_levels:, person_level:, assessment_id:, context: :self,
                 blocked: false, block_reason: nil, contribution: nil, secondary_contributions: [],
                 expanded: false, focused_level_ordinal: nil,
                 category_id: nil, frozen: false, alignment_locked: false,
                 viewer_person_id: nil, can_create_evidence: false,
                 can_relink_others_evidence: false)
    @capability_data = capability_data
    @capability = capability_data[:capability]
    @binding = capability_data[:binding]
    @weight = capability_data[:weight]
    @mandatory = @binding.deficit_threshold&.to_f == 0.0
    @blocked = blocked
    @block_reason = block_reason
    @contribution = contribution || capability_data[:contribution]
    @secondary_contributions = secondary_contributions
    @cells = capability_data[:cells]
    @merged_levels = merged_levels
    @person_level = person_level
    @assessment_id = assessment_id
    @context = context
    @has_illustrations = @cells.any? { |_, c| c[:illustration_count]&.positive? }
    @has_evidence = @cells.any? { |_, c| c[:evidence_count]&.positive? }
    @expandable = @has_illustrations || @has_evidence || can_create_evidence
    @expanded = expanded && @expandable
    @focused_level_ordinal = focused_level_ordinal
    @category_id = category_id
    @frozen = frozen
    @alignment_locked = alignment_locked
    @viewer_person_id = viewer_person_id
    @can_create_evidence = can_create_evidence
    @can_relink_others_evidence = can_relink_others_evidence
  end

  def view_template
    compact_row
    expanded_row if @expandable
  end

  private

  def compact_row
    tr(
      class: "hover:bg-gray-50 dark:hover:bg-gray-800/50 transition-colors " \
             "#{@expandable ? 'group cursor-pointer' : ''}",
      data: @expandable ? {
        action: "click->matrix#toggleRow",
        matrix_target: "row",
        capability_id: @capability.capability_id,
        # stable_id is also stored so matrix:focus-changed events carry
        # the cross-version identifier the activity feed entries use to
        # match focus state.
        capability_stable_id: @capability.stable_id
      } : {}
    ) do
      capability_name_cell
      @merged_levels.each do |level|
        render Views::Assessments::AssessmentCell.new(
          cell_data: @cells[level[:ordinal]],
          capability_id: @capability.capability_id,
          capability_name: @capability.name,
          capability_stable_id: @capability.stable_id,
          ordinal: level[:ordinal],
          level_label: level[:level_title].presence || level[:level_code],
          person_level: @person_level,
          assessment_id: @assessment_id,
          context: @context,
          category_id: @category_id,
          frozen: @frozen,
          alignment_locked: @alignment_locked
        )
      end
    end
  end

  def expanded_row
    expanded_data = { matrix_target: "expandedRow",
                      capability_id: @capability.capability_id,
                      capability_stable_id: @capability.stable_id }
    expanded_data[:focused_level_ordinal] = @focused_level_ordinal if @focused_level_ordinal

    tr(class: @expanded ? "" : "hidden", data: expanded_data) do
      td(class: "sticky left-0 z-[2] bg-blue-50/30 dark:bg-blue-900/10 " \
                "border-b border-r border-gray-100 dark:border-gray-800") { }

      @merged_levels.each do |level|
        expanded_cell(level[:ordinal])
      end
    end
  end

  def expanded_cell(ordinal)
    cell_data = @cells[ordinal]
    illustrations = cell_data&.dig(:illustrations) || []
    evidence = cell_data&.dig(:evidence) || []
    expectation = cell_data&.dig(:expectation)

    td(
      class: "px-3 py-2 border-b border-r border-gray-100 dark:border-gray-800 " \
             "bg-blue-50/30 dark:bg-blue-900/10 align-top cursor-pointer " \
             "hover:bg-blue-100/50 dark:hover:bg-blue-900/20 transition-colors",
      data: {
        action: "click->matrix#focusCell",
        capability_id: @capability.capability_id,
        capability_stable_id: @capability.stable_id,
        level_ordinal: ordinal,
        expectation_id: expectation&.expectation_id,
        focus_on_button_click: "true"
      }
    ) do
      if illustrations.any?
        ul(class: "space-y-1") do
          illustrations.each do |ill|
            li(class: "flex items-start gap-1.5 text-xs text-gray-600 dark:text-gray-400") do
              span(class: "mt-1 w-1 h-1 rounded-full bg-gray-400 dark:bg-gray-500 shrink-0") { }
              span { ill.description }
            end
          end
        end
      end

      if cell_data && @viewer_person_id && (evidence.any? || @can_create_evidence)
        render Views::Assessments::Evidence::List.new(
          items: evidence,
          assessment_id: @assessment_id,
          viewer_person_id: @viewer_person_id,
          can_create: @can_create_evidence,
          can_relink_others: @can_relink_others_evidence,
          capability_stable_id: @capability.stable_id,
          level_ordinal: ordinal
        )
      end
    end
  end

  def capability_name_cell
    render Views::Assessments::CapabilityNameCell.new(
      capability: @capability,
      weight: @weight,
      mandatory: @mandatory,
      blocked: @blocked,
      block_reason: @block_reason,
      contribution: @contribution,
      secondary_contributions: @secondary_contributions,
      has_illustrations: @has_illustrations,
      expanded: @expanded
    )
  end
end
