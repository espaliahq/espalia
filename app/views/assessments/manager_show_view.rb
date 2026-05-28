# frozen_string_literal: true

# Manager's view of a direct report's assessment.
# Unified sticky header with hero summary, category chips, and activity feed.
#
class Views::Assessments::ManagerShowView < Views::Base
  include Views::Assessments::HeaderChrome

  def initialize(assignment:, assessee:, framework:, matrix_data:, active_category_id: nil,
                 expanded_capability_id: nil, expanded_level_ordinal: nil,
                 context: :manager,
                 can_start_alignment: false, can_complete_alignment: false,
                 viewer_person_id: nil, can_create_evidence: false,
                 can_relink_others_evidence: false,
                 can_comment: false, viewer_is_tenant_admin: false,
                 activity_entries: [],
                 user: nil, current_tenant: nil, tenants: [])
    @assignment = assignment
    @assessee = assessee
    @framework = framework
    @matrix_data = matrix_data
    @active_category_id = active_category_id
    @expanded_capability_id = expanded_capability_id
    @expanded_level_ordinal = expanded_level_ordinal
    @context = context
    @can_start_alignment = can_start_alignment
    @can_complete_alignment = can_complete_alignment
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

  # ── Layout ──

  def assessment_layout
    div(data: { controller: "assessment-sync" }) do
      turbo_stream_from "assessment_updates", @assignment.framework_id, @assignment.person_id
      div(id: "assessment-sync-signal", class: "hidden",
          data: { assessment_sync_target: "signal" }) { }

      sticky_header
      div(class: "flex gap-6 items-start") do
        div(class: "flex-1 min-w-0") { main_section }
        activity_sidebar
      end
    end
  end

  def sticky_header
    div(id: "assessment-sticky-header",
        class: "sticky top-0 z-20 bg-gray-50 dark:bg-gray-950 -mx-6 px-6 pb-2",
        data: { controller: "category-nav" }) do
      assessment_header
      hero_frame
      category_chips
    end
  end

  def assessment_header
    div(class: "pt-4 pb-2") do
      a(href: assessments_path,
        class: "text-sm text-gray-500 dark:text-gray-400 hover:text-primary mb-1 inline-block") do
        plain "← Assessments"
      end

      div(class: "flex flex-wrap items-start justify-between gap-2") do
        div(class: "min-w-0 flex flex-wrap items-baseline gap-x-3 gap-y-1") do
          h1(class: "text-2xl font-bold text-gray-900 dark:text-white") do
            @assessee.name
          end
          span(class: "text-base text-gray-600 dark:text-gray-400") do
            @matrix_data[:level].title
          end
          render_shortcode_chip(role: @matrix_data[:role], level: @matrix_data[:level])
          render_status_pill(
            participant_status: @matrix_data[:participant_status],
            has_open_cycle: @assignment.current_open_cycle.present?
          )
        end

        div(class: "flex items-center gap-2 shrink-0") do
          mark_complete_button if @can_complete_alignment
          start_alignment_button if @can_start_alignment
          render Views::Assessments::Activity::PaneToggle.new(entry_count: @activity_entries.size)
        end
      end
    end
  end

  def start_alignment_button
    confirm_msg = "Starting alignment will lock self and manager ratings for this cycle. " \
      "You and #{@assessee.name} can still record agreed values together. Continue?"
    form(
      action: assessment_alignment_start_path(@assignment),
      method: "post",
      data: { turbo_confirm: confirm_msg },
      class: "inline"
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      button(
        type: "submit",
        class: "text-sm font-medium px-3 py-1.5 rounded-md border border-gray-300 " \
               "dark:border-gray-600 text-gray-700 dark:text-gray-300 " \
               "bg-white dark:bg-gray-800 hover:bg-gray-50 dark:hover:bg-gray-700 " \
               "cursor-pointer"
      ) { "Start alignment" }
    end
  end

  def mark_complete_button
    confirm_msg = "Marking alignment complete will lock all ratings for this cycle, " \
      "including the agreed values. Continue?"
    form(
      action: assessment_alignment_completion_path(@assignment),
      method: "post",
      data: { turbo_confirm: confirm_msg },
      class: "hidden md:inline-block"
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      button(
        type: "submit",
        class: "text-sm font-medium px-3 py-1.5 rounded-md " \
               "bg-green-600 dark:bg-green-700 text-white " \
               "hover:bg-green-700 dark:hover:bg-green-600 cursor-pointer"
      ) { "Mark alignment complete" }
    end
  end

  def hero_frame
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
        assignment: @assignment,
        can_start_alignment: @can_start_alignment,
        can_complete_alignment: @can_complete_alignment,
        assessee_name: @assessee.name
      )
    end
  end

  def category_chips
    render Views::Assessments::CategoryChipBar.new(
      categories: @matrix_data[:categories],
      scoring: primary_scoring,
      active_category_id: @active_category_id,
      context: @context
    )
  end

  def primary_scoring
    case @context
    when :manager   then @matrix_data[:manager_scoring] || @matrix_data[:scoring]
    when :alignment then @matrix_data[:aligned_scoring] || @matrix_data[:scoring]
    else @matrix_data[:scoring]
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
      class: "shrink-0 w-80 hidden " \
             "border border-gray-200 dark:border-gray-700 rounded-xl " \
             "bg-gray-50 dark:bg-gray-800/50 overflow-y-auto " \
             "sticky self-start max-h-[calc(100vh-2rem)]",
      style: "top: calc(var(--sticky-header-h, 0px) + 1rem)",
      data: { activity_pane_target: "pane", pane_state: "closed" }
    ) do
      activity_sidebar_header
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

  def activity_sidebar_header
    div(class: "flex items-center justify-between p-4 border-b border-gray-200 dark:border-gray-700") do
      span(class: "text-sm font-semibold text-gray-900 dark:text-white") { "Activity" }
      button(
        type: "button",
        class: "w-6 h-6 flex items-center justify-center rounded-full " \
               "text-gray-400 hover:text-gray-600 dark:hover:text-gray-300 " \
               "hover:bg-gray-200 dark:hover:bg-gray-700 transition-colors cursor-pointer",
        data: { action: "click->activity-pane#close" },
        aria: { label: "Close activity" }
      ) { plain "×" }
    end
  end

  def matrix_frame_params
    p = {}
    p[:capability] = @expanded_capability_id if @expanded_capability_id
    p[:level_ordinal] = @expanded_level_ordinal if @expanded_level_ordinal && @expanded_capability_id
    p
  end
end
