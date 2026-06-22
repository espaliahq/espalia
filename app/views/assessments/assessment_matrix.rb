# frozen_string_literal: true

# Card-based assessment view.
# Renders a category chip bar and all categories as scrollable sections,
# each containing capability cards with horizontal level strips.
#
# Replaces the old tabbed matrix table. Carries the same `data-controller="matrix"`
# and Turbo Stream target IDs so `assessment_sync_controller` and rating
# controllers work without changes.
#
class Views::Assessments::AssessmentMatrix < Views::Base
  # @param matrix_data [Hash] from Assessments::MatrixDataBuilder
  # @param assessment_id [String] UUID
  # @param context [Symbol] :self, :manager, or :alignment
  # @param expanded_capability_id [String, nil] pre-expanded capability stable_id
  # @param expanded_level_ordinal [Integer, nil] level ordinal pre-focused
  # @param selected_levels [Hash{String => Integer}] per-capability selected
  #   level map (`stable_id => ordinal`)
  # @param viewer_person_id [String, nil] threaded into the evidence section
  # @param can_create_evidence [Boolean]
  # @param can_relink_others_evidence [Boolean]
  # @param can_comment [Boolean]
  # @param viewer_is_tenant_admin [Boolean]
  def initialize(matrix_data:, assessment_id:, context: :self,
                 expanded_capability_id: nil,
                 expanded_level_ordinal: nil, selected_levels: {},
                 viewer_person_id: nil, can_create_evidence: false,
                 can_request_evidence: false,
                 can_relink_others_evidence: false,
                 can_comment: false, viewer_is_tenant_admin: false)
    @matrix_data = matrix_data
    @assessment_id = assessment_id
    @context = context
    @expanded_capability_id = expanded_capability_id
    @expanded_level_ordinal = expanded_level_ordinal
    @selected_levels = selected_levels
    @frozen = matrix_data[:individual_ratings_frozen] || false
    @alignment_locked = matrix_data[:alignment_locked] || false
    @viewer_person_id = viewer_person_id
    @can_create_evidence = can_create_evidence
    @can_request_evidence = can_request_evidence
    @can_relink_others_evidence = can_relink_others_evidence
    @can_comment = can_comment
    @viewer_is_tenant_admin = viewer_is_tenant_admin
  end

  def view_template
    div(data: {
      controller: "matrix",
      matrix_url_sync_value: true,
      matrix_active_category_id_value: first_category_id,
      action: "activity:navigate@window->matrix#navigateToEntity " \
              "assessment:focus-unrated@window->matrix#focusUnrated"
    }) do
      div(id: "matrix-header", class: "hidden") { }

      div(class: "space-y-8") do
        @matrix_data[:categories].each do |cat_data|
          render Views::Assessments::CategorySection.new(
            category_data: cat_data,
            merged_levels: @matrix_data[:merged_levels],
            person_level: @matrix_data[:person_level],
            assessment_id: @assessment_id,
            context: @context,
            scoring: @matrix_data[:scoring],
            self_scoring: @matrix_data[:self_scoring],
            manager_scoring: @matrix_data[:manager_scoring],
            aligned_scoring: @matrix_data[:aligned_scoring],
            expanded_capability_id: @expanded_capability_id,
            focused_level_ordinal: @expanded_level_ordinal,
            selected_levels: @selected_levels,
            frozen: @frozen,
            alignment_locked: @alignment_locked,
            viewer_person_id: @viewer_person_id,
            can_create_evidence: @can_create_evidence,
            can_request_evidence: @can_request_evidence,
            can_relink_others_evidence: @can_relink_others_evidence,
            can_comment: @can_comment,
            viewer_is_tenant_admin: @viewer_is_tenant_admin
          )
        end
      end
    end
  end

  private

  def first_category_id
    @matrix_data[:categories].first&.dig(:category)&.category_id
  end
end
