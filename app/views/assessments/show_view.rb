# frozen_string_literal: true

# Two-pane self-assessment page: matrix (main) + scoring panel (sidebar).
#
class Views::Assessments::ShowView < Views::Base
  # @param assignment [PersonFrameworkAssignment]
  # @param framework [FrameworkState::Framework]
  # @param matrix_data [Hash] output from Assessments::MatrixDataBuilder
  # @param user [User, nil]
  # @param current_tenant [Tenant, nil]
  # @param tenants [Array<Tenant>]
  def initialize(assignment:, framework:, matrix_data:, user: nil, current_tenant: nil, tenants: [])
    @assignment = assignment
    @framework = framework
    @matrix_data = matrix_data
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Kit::PageLayout.new(
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      div(data: { controller: "panel" }) do
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

      div(class: "flex items-center justify-between") do
        div do
          div(class: "flex items-center gap-3") do
            h1(class: "text-2xl font-bold text-gray-900 dark:text-white") { @framework.name }
            render Components::Kit::Badge.new("v#{@framework.current_published_version}", variant: :info)
          end
          div(class: "mt-1 flex items-center gap-2") do
            render Components::Kit::Badge.new(@matrix_data[:role].name, variant: :info)
            render Components::Kit::Badge.new(@matrix_data[:level].title, variant: :default)
            if @assignment.cycle_open?
              render Components::Kit::Badge.new("In Progress", variant: :warning)
            end
          end
        end

        # Mobile scoring toggle
        button(
          type: "button",
          class: "lg:hidden flex items-center gap-1.5 px-3 py-1.5 rounded-md " \
                 "bg-gray-100 dark:bg-gray-800 text-sm font-medium " \
                 "text-gray-700 dark:text-gray-300 hover:bg-gray-200 " \
                 "dark:hover:bg-gray-700 transition-colors",
          data: { action: "panel#toggle" }
        ) do
          plain "Scoring"
          score_percentage
        end
      end

      stats_bar
    end
  end

  def stats_bar
    total = @matrix_data[:total_cells]
    rated = @matrix_data[:rated_cells]

    div(class: "mt-3 flex items-center gap-6 text-sm text-gray-500 dark:text-gray-400") do
      span do
        span(class: "font-semibold text-gray-900 dark:text-white") { "#{rated}/#{total}" }
        plain " Rated"
      end
      span do
        span(class: "font-semibold text-gray-900 dark:text-white") do
          "#{format_ratio(@matrix_data[:scoring][:performance_ratio])}%"
        end
        plain " Performance"
      end
    end
  end

  def score_percentage
    ratio = @matrix_data[:scoring][:performance_ratio]
    pct = format_ratio(ratio)
    color = ratio >= 1.0 ? "text-green-600 dark:text-green-400" :
            ratio >= 0.8 ? "text-amber-600 dark:text-amber-400" :
            "text-red-600 dark:text-red-400"
    span(class: "ml-1 font-semibold #{color}") { "#{pct}%" }
  end

  # ── Layout ──

  def assessment_layout
    div(class: "flex -mx-6 -mb-6 h-[calc(100vh-14rem)] border-t border-gray-200 dark:border-gray-700") do
      main_pane
      scoring_sidebar
    end
  end

  def main_pane
    div(
      class: "flex-1 overflow-auto bg-white dark:bg-gray-900",
      data: { controller: "assessment-sync" }
    ) do
      turbo_stream_from "assessment_updates", @assignment.framework_id, @assignment.person_id
      div(id: "assessment-sync-signal", class: "hidden",
          data: { assessment_sync_target: "signal" }) { }
      turbo_frame_tag(
        "assessment-matrix",
        src: matrix_assessment_path(@assignment.framework_id),
        data: { assessment_sync_target: "frame" }
      ) do
        render Views::Assessments::Matrix.new(
          matrix_data: @matrix_data,
          framework_id: @framework.framework_id
        )
      end
    end
  end

  def scoring_sidebar
    aside(
      class: "w-80 shrink-0 border-l border-gray-200 dark:border-gray-700 " \
             "bg-gray-50 dark:bg-gray-800/50 overflow-y-auto " \
             "max-lg:hidden max-lg:fixed max-lg:right-0 max-lg:top-0 max-lg:bottom-0 max-lg:z-30 " \
             "max-lg:w-80 max-lg:shadow-xl",
      data: { panel_target: "panel" }
    ) do
      render Views::Assessments::ScoringPanel.new(
        scoring: @matrix_data[:scoring],
        categories: @matrix_data[:categories],
        person_level: @matrix_data[:person_level],
        mastery_threshold: @matrix_data[:mastery_threshold],
        meeting_expectation_threshold: @matrix_data[:meeting_expectation_threshold]
      )
    end
  end

  def format_ratio(ratio)
    ((ratio || 0.0) * 100).round(0).to_s
  end
end
