# frozen_string_literal: true

# Manager's view of a direct report's assessment.
# Unified sticky header with hero summary, category chips, and activity feed.
#
class Views::Assessments::ManagerShowView < Views::Base
  include Views::Assessments::HeaderChrome

  def initialize(assignment:, assessee:, framework:, matrix_data:, active_category_id: nil,
                 expanded_capability_id: nil, expanded_level_ordinal: nil,
                 selected_levels: {},
                 context: :manager,
                 can_start_alignment: false, can_complete_alignment: false,
                 can_reopen_alignment: false, can_start_lens_alignment: false, lens_viewer: :observer,
                 viewer_person_id: nil, can_create_evidence: false,
                 can_request_evidence: false,
                 can_relink_others_evidence: false,
                 can_comment: false, viewer_is_tenant_admin: false,
                 activity_entries: [],
                 exploration: nil, can_explore: false,
                 can_manage_delegates: false, active_delegations: [], candidate_delegates: [],
                 viewer_can_rate: true, unplaced_feedback_count: 0,
                 user: nil, current_tenant: nil, tenants: [])
    @assignment = assignment
    @unplaced_feedback_count = unplaced_feedback_count
    @assessee = assessee
    @framework = framework
    @matrix_data = matrix_data
    @active_category_id = active_category_id
    @expanded_capability_id = expanded_capability_id
    @expanded_level_ordinal = expanded_level_ordinal
    @selected_levels = selected_levels
    @context = context
    @can_start_alignment = can_start_alignment
    @can_complete_alignment = can_complete_alignment
    @can_reopen_alignment = can_reopen_alignment
    @can_start_lens_alignment = can_start_lens_alignment
    @lens_viewer = lens_viewer
    @viewer_person_id = viewer_person_id
    @can_create_evidence = can_create_evidence
    @can_request_evidence = can_request_evidence
    @can_relink_others_evidence = can_relink_others_evidence
    @can_comment = can_comment
    @viewer_is_tenant_admin = viewer_is_tenant_admin
    @activity_entries = activity_entries
    @exploration = exploration
    @can_explore = can_explore
    @can_manage_delegates = can_manage_delegates
    @active_delegations = active_delegations
    @candidate_delegates = candidate_delegates
    @viewer_can_rate = viewer_can_rate
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Shell::PageLayout.new(
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      div(data: { controller: "activity-pane", activity_pane_fit_viewport_value: true }) do
        assessment_layout
      end
    end
  end

  private

  # ── Layout ──

  def assessment_layout
    # See ShowView#assessment_layout — the unified evidence modal lives inside
    # assessment-sync so its submit arms the suppress window (in-place update).
    div(class: "assessment-scroll-root",
        data: { controller: "assessment-sync modal evidence-modal request-evidence",
                action: "keydown.esc@window->modal#escape" }) do
      turbo_stream_from "assessment_updates", @assignment.framework_id, @assignment.person_id
      div(id: "assessment-sync-signal", class: "hidden",
          data: { assessment_sync_target: "signal" }) { }
      # Pre-existing polite live region for the acting user's own rating
      # confirmations (WCAG 4.1.3 — audit issue #318). The rating Turbo
      # Stream responses update it; broadcasts never do.
      div(id: "assessment-live-status", role: "status", class: "sr-only") { }

      sticky_header
      if @unplaced_feedback_count.positive?
        render Views::Assessments::UnplacedFeedbackNotice.new(count: @unplaced_feedback_count, whose: @assessee.name)
      end
      div(class: "flex gap-6 items-start") do
        div(class: "flex-1 min-w-0") { main_section }
        activity_sidebar
      end

      # Root-mounted, so the hero's trigger can sit inside a frame that
      # reloads on every rating without taking an open dialog down with it.
      render Views::Assessments::ScoreExplainerModal.new(
        components: primary_scoring_components,
        state: primary_scoring_state,
        subject: "#{@assessee.name}'s score",
        merged_levels: @matrix_data[:merged_levels],
        person_level: @matrix_data[:person_level],
        thresholds: Views::Assessments::Glossary.thresholds_from(@matrix_data),
        emphasised: @matrix_data[:emphasised_capabilities],
        second_person: false
      )
      render_lens_role_modal(assessee_name: @assessee.name)
      render_exploration_modals(assessee_name: @assessee.name)
      render_start_lens_alignment_modal(assessee_name: @assessee.name, can_start_alignment: @can_start_lens_alignment)
      render Views::Evidence::ModalShell.new if @viewer_person_id.present?
      render Views::Evidence::RequestModalShell.new if @can_request_evidence
    end
  end

  # The perspective the hero renders, so the explainer opens on the same
  # numbers the reader is looking at.
  def primary_scoring
    @primary_scoring ||=
      case @context
      when :self      then @matrix_data[:self_scoring] || @matrix_data[:scoring]
      when :manager   then @matrix_data[:manager_scoring] || @matrix_data[:scoring]
      when :alignment then @matrix_data[:aligned_scoring] || @matrix_data[:scoring]
      else @matrix_data[:scoring]
      end
  end

  def primary_scoring_components = primary_scoring[:components]

  def primary_scoring_state = primary_scoring[:performance_state]

  def sticky_header
    # On md+ the whole header is sticky as one block. On mobile the
    # outer is left in flow — the hero alone would push the sticky
    # chrome past 80% of the viewport, leaving almost no room to read
    # the cards. Mobile users scroll to switch categories.
    div(id: "assessment-sticky-header",
        class: "md:sticky md:top-0 md:z-20 bg-page -mx-6 px-6 pb-2",
        data: { controller: "category-nav" }) do
      assessment_header
      hero_frame
      category_chips
    end
  end

  def assessment_header
    div(class: "pt-4 pb-2") do
      a(href: assessments_path,
        class: "text-sm text-muted hover:text-brand mb-1 inline-flex min-h-6 items-center") do
        plain "← Assessments"
      end

      div(class: "flex flex-wrap items-start justify-between gap-2") do
        div(class: "min-w-0 flex flex-wrap items-baseline gap-x-3 gap-y-1") do
          h1(class: "text-2xl font-bold text-default") do
            @assessee.name
          end
          span(class: "text-base text-muted") do
            @matrix_data[:level].title
          end
          render_lens_control(assessee_name: @assessee.name)
          render_status_pill_unless_lens(
            participant_status: @matrix_data[:participant_status],
            has_open_cycle: @assignment.current_open_cycle.present?,
            context: :manager,
            current_level_complete: @matrix_data[:current_level_complete],
            work: @matrix_data[:current_level_work]
          )
          render_lens_alignment_chips
        end

        div(class: "flex items-center gap-2 shrink-0") do
          delegates_button if @can_manage_delegates
          mark_complete_button if @can_complete_alignment
          start_alignment_button if @can_start_alignment
          reopen_alignment_button if @can_reopen_alignment
          render Views::Assessments::Activity::PaneToggle.new(entry_count: @activity_entries.size)
        end
      end
      render_lens_banner(assessee_name: @assessee.name, can_start_alignment: @can_start_lens_alignment,
                         viewer: @lens_viewer)
    end
  end

  def start_alignment_button
    code = @matrix_data[:lens]&.home_code || "#{@matrix_data[:role].code}#{@matrix_data[:person_level]}"
    confirm_msg = "Starting alignment will lock self and manager ratings on #{code}'s capabilities. " \
      "You and #{@assessee.name} can still record agreed values together. Continue?"
    form(
      action: assessment_alignment_start_path(@assignment),
      method: "post",
      data: { turbo_confirm: confirm_msg },
      class: "inline"
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      render Components::Kit::Button.new(variant: :outline, size: :sm, type: :submit) { "Start alignment" }
    end
  end

  # Gated on full current-level aligned coverage — disabled with a jump
  # chip while cells remain, live form once whole. Replaced in place by
  # the alignment-rating Turbo Stream responses so it enables the moment
  # the last cell is agreed.
  def mark_complete_button
    render Views::Assessments::AlignmentCompletionControl.new(
      assignment: @assignment,
      matrix_data: @matrix_data,
      lens_params: lens_params
    )
  end

  def reopen_alignment_button
    confirm_msg = "Re-open alignment#{against_lens} for this cycle? Self and manager ratings stay locked and " \
      "the agreed values are kept — you can adjust them and mark complete again."
    form(
      action: assessment_alignment_reopening_path(@assignment, lens_params),
      method: "post",
      data: { turbo_confirm: confirm_msg },
      # Desktop-only, matching mark_complete_button: re-open pairs with
      # re-completion, so both finalizing actions live at the same breakpoint
      # (a mobile re-open with no mobile re-complete would strand the manager).
      class: "hidden md:inline-block"
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      render Components::Kit::Button.new(variant: :outline, size: :sm, type: :submit) { "Re-open alignment#{against_lens}" }
    end
  end

  # " against PM3" when the milestone is a lens role's (ADR-22).
  def against_lens
    lens = off_record_lens
    lens && !lens.home_role? ? " against #{lens.code}" : ""
  end

  def delegates_button
    count = @active_delegations.size
    label = count.positive? ? "Delegates · #{count}" : "Delegates"
    render Components::Kit::Modal.new(id: "delegate-modal", title: "Manage delegates") do |modal|
      modal.trigger { label }
      modal.body do
        p(class: "text-sm text-muted mb-3") do
          "Delegates can record manager ratings for #{@assessee.name} but cannot start or " \
            "complete alignment."
        end
        render Views::Assessments::Delegations::Frame.new(
          assignment: @assignment,
          active_delegations: @active_delegations,
          candidate_delegates: @candidate_delegates
        )
      end
    end
  end

  def hero_frame
    turbo_frame_tag(
      "assessment-scoring",
      src: scoring_assessment_path(@assignment, lens_params),
      data: { assessment_sync_target: "scoringFrame" }
    ) do
      render Views::Assessments::HeroSummary.new(
        scoring: @matrix_data[:scoring],
        self_scoring: @matrix_data[:self_scoring],
        manager_scoring: @matrix_data[:manager_scoring],
        aligned_scoring: @matrix_data[:aligned_scoring],
        thresholds: Views::Assessments::Glossary.thresholds_from(@matrix_data),
        categories: @matrix_data[:categories],
        person_level: @matrix_data[:person_level],
        merged_levels: @matrix_data[:merged_levels],
        assessment_id: @assignment.id,
        context: @context,
        # The manager-side view — the manager's own rating leads
        # (top-left split / first secondary percentage) in alignment.
        viewer_is_manager: true,
        assessee_name: @assessee.name,
        viewer_can_rate: @viewer_can_rate,
        alignment_locked: @matrix_data[:alignment_locked],
        lens: @matrix_data[:lens],
        ratings_frozen: @matrix_data[:individual_ratings_frozen]
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
        viewer_is_manager: true,
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

  def activity_sidebar
    aside(
      id: "assessment-activity-pane",
      # The height cap subtracts the sticky header the pane sits under, or its
      # bottom (and the feed's last entries) lands below the viewport. Both
      # offsets are lg-only so the overlay below lg keeps its full height.
      class: "hidden bg-subtle overflow-auto overscroll-contain " \
             "border border-default " \
             "max-lg:fixed max-lg:inset-y-0 max-lg:right-0 max-lg:z-30 " \
             "max-lg:w-80 max-lg:shadow-overlay max-lg:border-l max-lg:rounded-none " \
             "lg:shrink-0 lg:w-80 lg:rounded-xl lg:sticky lg:self-start " \
             "lg:top-[calc(var(--sticky-header-h,0px)+1rem)] " \
             "lg:max-h-[calc(100dvh-var(--sticky-header-h,0px)-2rem)]",
      data: { activity_pane_target: "pane", pane_state: "closed" }
    ) do
      # No separate sidebar header — the feed's own header carries
      # "Activity" + entry count + close button so it all lives in
      # one row (and the count re-renders with the feed on ActionCable
      # broadcasts).
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
    p = lens_params.dup
    p[:capability] = @expanded_capability_id if @expanded_capability_id
    p[:level_ordinal] = @expanded_level_ordinal if @expanded_level_ordinal && @expanded_capability_id
    p[:levels] = @selected_levels if @selected_levels.present?
    p
  end
end
