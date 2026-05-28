# frozen_string_literal: true

# Self-assessment page with card-based layout.
#
# Single-column scroll: hero summary (sticky) → category chip bar →
# capability cards grouped by category. Activity feed as a right
# slide-over pane.
#
class Views::Assessments::ShowView < Views::Base
  include Views::Assessments::HeaderChrome

  # @param assignment [PersonFrameworkAssignment]
  # @param framework [FrameworkState::Framework]
  # @param matrix_data [Hash] output from Assessments::MatrixDataBuilder
  # @param active_category_id [String, nil] highlighted category chip
  # @param expanded_capability_id [String, nil] pre-expanded capability stable_id
  # @param viewer_person_id [String, nil] threaded into the evidence section
  # @param can_create_evidence [Boolean] whether to render the "+ Add evidence" affordance
  # @param can_relink_others_evidence [Boolean] whether to render the relink kebab option
  # @param activity_entries [Array<Assessments::ActivityFeedQuery::Entry>]
  # @param user [User, nil]
  # @param current_tenant [Tenant, nil]
  # @param tenants [Array<Tenant>]
  def initialize(assignment:, framework:, matrix_data:, active_category_id: nil,
                 expanded_capability_id: nil, expanded_level_ordinal: nil,
                 context: :self,
                 viewer_person_id: nil, can_create_evidence: false,
                 can_relink_others_evidence: false,
                 can_comment: false, viewer_is_tenant_admin: false,
                 activity_entries: [],
                 user: nil, current_tenant: nil, tenants: [])
    @assignment = assignment
    @framework = framework
    @matrix_data = matrix_data
    @active_category_id = active_category_id
    @expanded_capability_id = expanded_capability_id
    @expanded_level_ordinal = expanded_level_ordinal
    @context = context
    @viewer_person_id = viewer_person_id
    @can_create_evidence = can_create_evidence
    @can_relink_others_evidence = can_relink_others_evidence
    @can_comment = can_comment
    @viewer_is_tenant_admin = viewer_is_tenant_admin
    @activity_entries = activity_entries
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def can_render_relink_modal?
    @viewer_person_id.present? && (@can_create_evidence || @can_relink_others_evidence)
  end

  def can_render_edit_modal?
    @viewer_person_id.present?
  end

  def view_template
    render Components::Kit::PageLayout.new(
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      controllers = [
        "activity-pane",
        ("evidence-form" if @can_create_evidence),
        ("evidence-relink-form" if can_render_relink_modal?),
        ("evidence-edit-form" if can_render_edit_modal?)
      ].compact.join(" ")
      esc_actions = [
        ("keydown.esc->evidence-form#close" if @can_create_evidence),
        ("keydown.esc->evidence-relink-form#close" if can_render_relink_modal?),
        ("keydown.esc->evidence-edit-form#close" if can_render_edit_modal?)
      ].compact.join(" ")
      data = { controller: controllers }
      data[:action] = esc_actions if esc_actions.present?
      data[:evidence_relink_form_assessment_id_value] = @assignment.id if can_render_relink_modal?
      data[:evidence_edit_form_assessment_id_value] = @assignment.id if can_render_edit_modal?
      div(data: data) do
        assessment_header
        assessment_layout
        render Views::Assessments::Evidence::Form.new(assessment_id: @assignment.id) if @can_create_evidence
        if can_render_relink_modal?
          render Views::Assessments::Evidence::RelinkForm.new(
            categories: @matrix_data[:categories],
            merged_levels: @matrix_data[:merged_levels]
          )
        end
        render Views::Assessments::Evidence::EditForm.new(assessment_id: @assignment.id) if can_render_edit_modal?
      end
    end
  end

  private

  # ── Header ──

  def assessment_header
    div(class: "mb-4") do
      a(href: assessments_path,
        class: "text-sm text-gray-500 dark:text-gray-400 hover:text-primary mb-2 inline-block") do
        plain "← My Assessments"
      end

      div(class: "flex flex-wrap items-start justify-between gap-2") do
        div(class: "min-w-0 flex flex-wrap items-baseline gap-x-3 gap-y-1") do
          h1(class: "text-2xl font-bold text-gray-900 dark:text-white") do
            @matrix_data[:level].title
          end
          render_shortcode_chip(role: @matrix_data[:role], level: @matrix_data[:level])
          render_status_pill(
            participant_status: @matrix_data[:participant_status],
            has_open_cycle: @assignment.current_open_cycle.present?
          )
        end

        div(class: "flex items-center gap-2 shrink-0") do
          render Views::Assessments::Activity::PaneToggle.new(entry_count: @activity_entries.size)
        end
      end
    end
  end

  # ── Layout ──

  def assessment_layout
    div(data: { controller: "assessment-sync" }) do
      turbo_stream_from "assessment_updates", @assignment.framework_id, @assignment.person_id
      div(id: "assessment-sync-signal", class: "hidden",
          data: { assessment_sync_target: "signal" }) { }

      hero_section
      main_section
      activity_sidebar
    end
  end

  def hero_section
    div(class: "sticky top-0 z-20") do
      turbo_frame_tag(
        "assessment-scoring",
        src: scoring_assessment_path(@assignment),
        data: { assessment_sync_target: "scoringFrame" }
      ) do
        render Views::Assessments::HeroSummary.new(
          scoring: @matrix_data[:scoring],
          self_scoring: @matrix_data[:self_scoring],
          manager_scoring: @matrix_data[:manager_scoring],
          aligned_scoring: @matrix_data[:aligned_scoring],
          categories: @matrix_data[:categories],
          person_level: @matrix_data[:person_level],
          merged_levels: @matrix_data[:merged_levels],
          mastery_threshold: @matrix_data[:mastery_threshold],
          meeting_expectation_threshold: @matrix_data[:meeting_expectation_threshold],
          assessment_id: @assignment.id,
          context: @context,
          assignment: @assignment
        )
      end
    end
  end

  def main_section
    turbo_frame_tag(
      "assessment-matrix",
      src: matrix_assessment_path(@assignment, matrix_frame_params),
      data: { assessment_sync_target: "frame" }
    ) do
      render Views::Assessments::AssessmentMatrix.new(
        matrix_data: @matrix_data,
        assessment_id: @assignment.id,
        context: @context,
        active_category_id: @active_category_id,
        expanded_capability_id: @expanded_capability_id,
        expanded_level_ordinal: @expanded_level_ordinal,
        viewer_person_id: @viewer_person_id,
        can_create_evidence: @can_create_evidence,
        can_relink_others_evidence: @can_relink_others_evidence,
        can_comment: @can_comment,
        viewer_is_tenant_admin: @viewer_is_tenant_admin
      )
    end
  end

  def activity_sidebar
    aside(
      id: "assessment-activity-pane",
      class: "fixed right-0 top-0 bottom-0 z-30 w-80 " \
             "border-l border-gray-200 dark:border-gray-700 " \
             "bg-gray-50 dark:bg-gray-800/50 overflow-y-auto hidden shadow-xl",
      data: { activity_pane_target: "pane", pane_state: "closed" }
    ) do
      turbo_frame_tag(
        "assessment-activity",
        src: assessment_activity_path(@assignment),
        loading: "lazy",
        data: { assessment_sync_target: "activityFrame" }
      ) do
        render Views::Assessments::Activity::Feed.new(
          entries: @activity_entries,
          assignment: @assignment
        )
      end
    end
  end

  def matrix_frame_params
    p = {}
    p[:capability] = @expanded_capability_id if @expanded_capability_id
    p[:level_ordinal] = @expanded_level_ordinal if @expanded_level_ordinal && @expanded_capability_id
    p
  end
end
