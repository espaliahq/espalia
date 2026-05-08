# frozen_string_literal: true

# Tabbed assessment capability matrix.
# Renders a category tab bar above the matrix table, showing one category at a time.
# Passes context and all scoring perspectives through to AssessmentCategoryGroup children.
#
# The tab bar is rendered outside the horizontally-scrollable table wrapper so it
# remains fixed at the top when the user scrolls the matrix left/right.
#
class Views::Assessments::AssessmentMatrix < Views::Base
  # @param matrix_data [Hash] from Assessments::MatrixDataBuilder
  # @param assessment_id [String] UUID
  # @param context [Symbol] :self, :manager, or :alignment
  # @param active_category_id [String, nil] selected category tab
  # @param expanded_capability_id [String, nil] pre-expanded capability stable_id
  # @param expanded_level_ordinal [Integer, nil] level ordinal pre-focused
  #   within the expanded row (cell-level deep link)
  # @param viewer_person_id [String, nil] threaded into the evidence section
  # @param can_create_evidence [Boolean] whether the viewer can record evidence
  # @param can_relink_others_evidence [Boolean] whether the viewer can relink
  #   evidence they didn't author (assessee or in their manager chain)
  def initialize(matrix_data:, assessment_id:, context: :self,
                 active_category_id: nil, expanded_capability_id: nil,
                 expanded_level_ordinal: nil,
                 viewer_person_id: nil, can_create_evidence: false,
                 can_relink_others_evidence: false)
    @matrix_data = matrix_data
    @assessment_id = assessment_id
    @context = context
    @active_category_id = active_category_id || first_category_id
    @expanded_capability_id = expanded_capability_id
    @expanded_level_ordinal = expanded_level_ordinal
    @frozen = matrix_data[:individual_ratings_frozen] || false
    @alignment_locked = matrix_data[:alignment_locked] || false
    @viewer_person_id = viewer_person_id
    @can_create_evidence = can_create_evidence
    @can_relink_others_evidence = can_relink_others_evidence
  end

  def view_template
    div(data: {
      controller: "matrix",
      matrix_url_sync_value: true,
      # Stamping the active category here lets matrix_controller's
      # connect dispatch initial focus on every frame load (tab switch,
      # rating broadcast, etc.) so the activity feed picks up the
      # implicit category narrowing without the user having to expand
      # a row first.
      matrix_active_category_id_value: @active_category_id,
      action: "activity:navigate@window->matrix#navigateToEntity"
    }) do
      render Views::Assessments::CategoryTabs.new(
        categories: @matrix_data[:categories],
        scoring: primary_scoring,
        self_scoring: @matrix_data[:self_scoring],
        manager_scoring: @matrix_data[:manager_scoring],
        aligned_scoring: @matrix_data[:aligned_scoring],
        active_category_id: @active_category_id,
        assessment_id: @assessment_id,
        context: @context
      )
      div(class: "overflow-x-auto") do
        # Default state: `table-auto` (no `table-fixed` class). Each
        # level <col> gets a default 280px width so the
        # FrequencySelector's four buttons (including "Consistently")
        # fit on a single line at any framework size. With many levels,
        # the table grows past the container's width and the parent's
        # overflow-x-auto scrolls. matrix_controller#applyColumnFocus
        # toggles `table-layout: fixed` and overrides each <col>'s
        # width when a cell is focused.
        table(class: "w-full border-collapse") do
          colgroup do
            col(style: "width: 220px",
                data: { matrix_target: "col", level_ordinal: "capability" })
            @matrix_data[:merged_levels].each do |level|
              col(style: "width: 280px",
                  data: { matrix_target: "col", level_ordinal: level[:ordinal] })
            end
          end
          render Views::Assessments::MatrixHeader.new(
            merged_levels: @matrix_data[:merged_levels],
            person_level: @matrix_data[:person_level],
            inferred_level: @matrix_data[:inferred_level]
          )
          tbody do
            active_category = find_active_category
            if active_category
              render Views::Assessments::AssessmentCategoryGroup.new(
                category_data: active_category,
                merged_levels: @matrix_data[:merged_levels],
                person_level: @matrix_data[:person_level],
                scoring: @matrix_data[:scoring],
                self_scoring: @matrix_data[:self_scoring],
                manager_scoring: @matrix_data[:manager_scoring],
                aligned_scoring: @matrix_data[:aligned_scoring],
                assessment_id: @assessment_id,
                context: @context,
                expanded_capability_id: @expanded_capability_id,
                expanded_level_ordinal: @expanded_level_ordinal,
                show_header: false,
                frozen: @frozen,
                alignment_locked: @alignment_locked,
                viewer_person_id: @viewer_person_id,
                can_create_evidence: @can_create_evidence,
                can_relink_others_evidence: @can_relink_others_evidence
              )
            end
          end
        end
      end
    end
  end

  private

  def first_category_id
    @matrix_data[:categories].first&.dig(:category)&.category_id
  end

  def find_active_category
    @matrix_data[:categories].find { |c| c[:category].category_id == @active_category_id }
  end

  # Returns the primary scoring hash based on the current context.
  #
  # @return [Hash]
  def primary_scoring
    case @context
    when :self      then @matrix_data[:self_scoring] || @matrix_data[:scoring]
    when :manager   then @matrix_data[:manager_scoring] || @matrix_data[:scoring]
    when :alignment then @matrix_data[:aligned_scoring] || @matrix_data[:scoring]
    else @matrix_data[:scoring]
    end
  end
end
