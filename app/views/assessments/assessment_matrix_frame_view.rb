# frozen_string_literal: true

# Turbo Frame wrapper for the unified assessment matrix.
# Rendered by AssessmentsController#matrix for frame-only refreshes.
#
class Views::Assessments::AssessmentMatrixFrameView < Views::Base
  # @param framework [FrameworkState::Framework]
  # @param matrix_data [Hash]
  # @param assignment [PersonFrameworkAssignment]
  # @param context [Symbol] :self, :manager, or :alignment
  # @param viewer_is_manager [Boolean] whether the viewer is the manager-side
  #   party — threaded down so split chips put the viewer's own rating top-left
  # @param active_category_id [String, nil] active tab category ID
  # @param expanded_capability_id [String, nil] pre-expanded capability stable_id
  # @param selected_levels [Hash{String => Integer}] per-capability selected
  #   level map (`stable_id => ordinal`)
  def initialize(framework:, matrix_data:, assignment:, context: :self,
                 viewer_is_manager: false,
                 active_category_id: nil, expanded_capability_id: nil,
                 expanded_level_ordinal: nil, selected_levels: {},
                 viewer_person_id: nil, can_create_evidence: false,
                 can_request_evidence: false,
                 can_relink_others_evidence: false,
                 can_comment: false, viewer_is_tenant_admin: false)
    @framework = framework
    @matrix_data = matrix_data
    @assignment = assignment
    @context = context
    @viewer_is_manager = viewer_is_manager
    @active_category_id = active_category_id
    @expanded_capability_id = expanded_capability_id
    @expanded_level_ordinal = expanded_level_ordinal
    @selected_levels = selected_levels
    @viewer_person_id = viewer_person_id
    @can_create_evidence = can_create_evidence
    @can_request_evidence = can_request_evidence
    @can_relink_others_evidence = can_relink_others_evidence
    @can_comment = can_comment
    @viewer_is_tenant_admin = viewer_is_tenant_admin
  end

  def view_template
    turbo_frame_tag("assessment-matrix") do
      render Views::Assessments::AssessmentMatrix.new(
        matrix_data: @matrix_data,
        assessment_id: @assignment.id,
        context: @context,
        viewer_is_manager: @viewer_is_manager,
        expanded_capability_id: @expanded_capability_id,
        expanded_level_ordinal: @expanded_level_ordinal,
        selected_levels: @selected_levels,
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
