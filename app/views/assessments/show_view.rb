# frozen_string_literal: true

# Self-assessment page with card-based layout.
#
# Unified sticky header: back link + title + hero summary + category
# chips all pin together when scrolled. Activity feed as a right
# slide-over pane.
#
class Views::Assessments::ShowView < Views::Base
  include Views::Assessments::HeaderChrome

  # @param assignment [PersonFrameworkAssignment]
  # @param framework [FrameworkState::Framework]
  # @param matrix_data [Hash] output from Assessments::MatrixDataBuilder
  # @param active_category_id [String, nil] highlighted category chip
  # @param expanded_capability_id [String, nil] pre-expanded capability stable_id
  # @param selected_levels [Hash{String => Integer}] per-capability selected
  #   level map (`stable_id => ordinal`) — each card renders its own selected
  #   level (see assessments.md)
  # @param viewer_person_id [String, nil] threaded into the evidence section
  # @param can_create_evidence [Boolean] whether to render the "+ Add evidence" affordance
  # @param can_relink_others_evidence [Boolean] whether the viewer may manage
  #   links (add/remove capability × level) on evidence authored by others
  # @param activity_entries [Array<Assessments::ActivityFeedQuery::Entry>]
  # @param exploration [AssessmentExploration, nil] the open exploration of
  #   the lens role (ADR-22)
  # @param can_explore [Boolean] the viewer may declare or close one
  # @param user [User, nil]
  # @param current_tenant [Tenant, nil]
  # @param tenants [Array<Tenant>]
  def initialize(assignment:, framework:, matrix_data:, active_category_id: nil,
                 expanded_capability_id: nil, expanded_level_ordinal: nil,
                 selected_levels: {},
                 context: :self,
                 viewer_person_id: nil, can_create_evidence: false,
                 can_request_evidence: false,
                 can_relink_others_evidence: false,
                 can_comment: false, viewer_is_tenant_admin: false,
                 activity_entries: [],
                 exploration: nil, can_explore: false,
                 user: nil, current_tenant: nil, tenants: [])
    @assignment = assignment
    @framework = framework
    @matrix_data = matrix_data
    @active_category_id = active_category_id
    @expanded_capability_id = expanded_capability_id
    @expanded_level_ordinal = expanded_level_ordinal
    @selected_levels = selected_levels
    @context = context
    @viewer_person_id = viewer_person_id
    @can_create_evidence = can_create_evidence
    @can_request_evidence = can_request_evidence
    @can_relink_others_evidence = can_relink_others_evidence
    @can_comment = can_comment
    @viewer_is_tenant_admin = viewer_is_tenant_admin
    @activity_entries = activity_entries
    @exploration = exploration
    @can_explore = can_explore
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Kit::PageLayout.new(
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      div(data: { controller: "activity-pane" }) do
        assessment_layout
      end
    end
  end

  private

  # ── Layout ──

  def assessment_layout
    # `modal` + `evidence-modal` live here (not on an outer wrapper) so the
    # unified evidence modal — overlay, frame, and its submit — sits INSIDE the
    # assessment-sync element; the submit then arms the suppress window and the
    # matrix updates in place instead of fully reloading.
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
      # Main + activity sit side-by-side. When the activity sidebar
      # is `hidden`, the main pane gets the full width; when shown,
      # it compresses to make room.
      div(class: "flex gap-6 items-start") do
        div(class: "flex-1 min-w-0") { main_section }
        activity_sidebar
      end

      # Root-mounted, so the hero's trigger can sit inside a frame that
      # reloads on every rating without taking an open dialog down with it.
      render Views::Assessments::ScoreExplainerModal.new(
        components: primary_scoring_components,
        state: primary_scoring_state,
        subject: "Your score",
        merged_levels: @matrix_data[:merged_levels],
        person_level: @matrix_data[:person_level],
        thresholds: Views::Assessments::Glossary.thresholds_from(@matrix_data),
        emphasised: @matrix_data[:emphasised_capabilities],
        second_person: true
      )
      render_lens_role_modal(assessee_name: nil)
      render_exploration_modals(assessee_name: nil)
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
    # See manager_show_view#sticky_header for the rationale on the
    # md+-only outer sticky (mobile keeps everything in flow).
    div(id: "assessment-sticky-header",
        class: "md:sticky md:top-0 md:z-20 bg-gray-50 dark:bg-gray-950 -mx-6 px-6 pb-2",
        data: { controller: "category-nav" }) do
      assessment_header
      hero_frame
      category_chips
    end
  end

  def assessment_header
    div(class: "pt-4 pb-2") do
      a(href: assessments_path,
        class: "text-sm text-gray-600 dark:text-gray-300 hover:text-primary mb-1 inline-block") do
        plain "← My Assessments"
      end

      div(class: "flex flex-wrap items-start justify-between gap-2") do
        div(class: "min-w-0 flex flex-wrap items-baseline gap-x-3 gap-y-1") do
          h1(class: "text-2xl font-bold text-gray-900 dark:text-white") do
            @matrix_data[:level].title
          end
          render_lens_control(assessee_name: nil)
          render_status_pill_unless_lens(
            participant_status: @matrix_data[:participant_status],
            has_open_cycle: @assignment.current_open_cycle.present?,
            current_level_complete: @matrix_data[:current_level_complete]
          )
          render_lens_alignment_chips
        end

        div(class: "flex items-center gap-2 shrink-0") do
          render Views::Assessments::Activity::PaneToggle.new(entry_count: @activity_entries.size)
        end
      end
      render_lens_banner
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
        # The assessee's own view — in alignment their Self rating leads
        # (top-left split / first secondary percentage).
        viewer_is_manager: false,
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
    when :self      then @matrix_data[:self_scoring] || @matrix_data[:scoring]
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
        viewer_is_manager: false,
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
    # On lg+ viewports, the sidebar sits inline next to the matrix and
    # compresses it when open. On smaller viewports it overlays (fixed)
    # so the matrix gets the full width and isn't squeezed to nothing.
    aside(
      id: "assessment-activity-pane",
      class: "hidden bg-gray-50 dark:bg-gray-800 overflow-auto " \
             "border border-gray-200 dark:border-gray-700 " \
             "max-lg:fixed max-lg:inset-y-0 max-lg:right-0 max-lg:z-30 " \
             "max-lg:w-80 max-lg:shadow-xl max-lg:border-l max-lg:rounded-none " \
             "lg:shrink-0 lg:w-80 lg:rounded-xl " \
             "lg:sticky lg:self-start lg:max-h-[calc(100vh-2rem)]",
      style: "top: calc(var(--sticky-header-h, 0px) + 1rem)",
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
