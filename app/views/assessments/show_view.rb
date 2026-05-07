# frozen_string_literal: true

# Two-pane self-assessment page: matrix (main) + scoring panel (sidebar).
#
class Views::Assessments::ShowView < Views::Base
  include Views::Assessments::HeaderChrome

  # @param assignment [PersonFrameworkAssignment]
  # @param framework [FrameworkState::Framework]
  # @param matrix_data [Hash] output from Assessments::MatrixDataBuilder
  # @param active_category_id [String, nil] active tab category ID
  # @param expanded_capability_id [String, nil] pre-expanded capability stable_id
  # @param user [User, nil]
  # @param current_tenant [Tenant, nil]
  # @param tenants [Array<Tenant>]
  def initialize(assignment:, framework:, matrix_data:, active_category_id: nil,
                 expanded_capability_id: nil, context: :self,
                 user: nil, current_tenant: nil, tenants: [])
    @assignment = assignment
    @framework = framework
    @matrix_data = matrix_data
    @active_category_id = active_category_id
    @expanded_capability_id = expanded_capability_id
    @context = context
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Kit::PageLayout.new(
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      div(data: { controller: "panel", panel_side_value: "left" }) do
        assessment_header
        assessment_layout
      end
    end
  end

  private

  # ── Header ──

  def assessment_header
    div(class: "mb-4") do
      a(href: assessments_path,
        class: "text-sm text-gray-500 dark:text-gray-400 hover:text-primary mb-2 inline-block") do
        plain "\u2190 My Assessments"
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
          mobile_scoring_toggle
        end
      end
    end
  end

  def mobile_scoring_toggle
    button(
      type: "button",
      class: "lg:hidden shrink-0 flex items-center gap-1.5 px-3 py-1.5 rounded-md " \
             "bg-gray-100 dark:bg-gray-800 text-sm font-medium " \
             "text-gray-700 dark:text-gray-300 hover:bg-gray-200 " \
             "dark:hover:bg-gray-700 transition-colors",
      data: { action: "panel#toggle" }
    ) do
      plain "Scoring"
      score_percentage
    end
  end

  def score_percentage
    scoring = primary_scoring
    ratio = scoring[:performance_ratio]
    pct = format_ratio(ratio)
    color = ratio >= 1.0 ? "text-green-600 dark:text-green-400" :
            ratio >= 0.8 ? "text-amber-600 dark:text-amber-400" :
            "text-red-600 dark:text-red-400"
    span(id: "score-percentage-badge", class: "ml-1 font-semibold #{color}") { "#{pct}%" }
  end

  def primary_scoring
    case @context
    when :alignment then @matrix_data[:aligned_scoring] || @matrix_data[:scoring]
    else                 @matrix_data[:self_scoring] || @matrix_data[:scoring]
    end
  end

  # ── Layout ──

  def assessment_layout
    div(
      class: "flex -mx-6 -mb-6 h-[calc(100vh-14rem)] border-t border-gray-200 dark:border-gray-700",
      data: { controller: "assessment-sync" }
    ) do
      turbo_stream_from "assessment_updates", @assignment.framework_id, @assignment.person_id
      div(id: "assessment-sync-signal", class: "hidden",
          data: { assessment_sync_target: "signal" }) { }
      scoring_sidebar
      main_pane
    end
  end

  def main_pane
    div(class: "flex-1 overflow-auto bg-white dark:bg-gray-900") do
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
          expanded_capability_id: @expanded_capability_id
        )
      end
    end
  end

  def scoring_sidebar
    aside(
      class: "w-72 shrink-0 border-r border-gray-200 dark:border-gray-700 " \
             "bg-gray-50 dark:bg-gray-800/50 overflow-y-auto " \
             "max-lg:hidden max-lg:fixed max-lg:left-0 max-lg:top-0 max-lg:bottom-0 max-lg:z-30 " \
             "max-lg:w-72 max-lg:shadow-xl",
      data: { panel_target: "panel" }
    ) do
      turbo_frame_tag(
        "assessment-scoring",
        src: scoring_assessment_path(@assignment, scoring_frame_params),
        data: { assessment_sync_target: "scoringFrame" }
      ) do
        render Views::Assessments::ScoringPanel.new(
          scoring: @matrix_data[:scoring],
          self_scoring: @matrix_data[:self_scoring],
          manager_scoring: @matrix_data[:manager_scoring],
          aligned_scoring: @matrix_data[:aligned_scoring],
          categories: @matrix_data[:categories],
          person_level: @matrix_data[:person_level],
          mastery_threshold: @matrix_data[:mastery_threshold],
          meeting_expectation_threshold: @matrix_data[:meeting_expectation_threshold],
          active_category_id: @active_category_id,
          assessment_id: @assignment.id,
          context: @context
        )
      end
    end
  end

  def matrix_frame_params
    p = {}
    p[:category] = @active_category_id if @active_category_id
    p[:capability] = @expanded_capability_id if @expanded_capability_id
    p
  end

  def scoring_frame_params
    p = {}
    p[:category] = @active_category_id if @active_category_id
    p
  end

  def format_ratio(ratio)
    ((ratio || 0.0) * 100).round(0).to_s
  end
end
