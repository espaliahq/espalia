# frozen_string_literal: true

# Content for the "Cycle progress (your org)" card — a teaser for one open
# cycle. Mini funnel + at-risk count + the most-lagging subtree, with a CTA into
# the full drill-down. Counts only, never rating values.
class Views::Home::Cards::CycleProgress < Views::Base
  # @param cycle [AssessmentCycle]
  # @param result [Reporting::CycleCohort::Result] summary-mode result
  def initialize(cycle:, result:)
    @cycle = cycle
    @result = result
  end

  def view_template
    render Components::Kit::Card.new do |card|
      card.body do
        header
        mini_funnel
        attention_line
      end
      card.actions { view_link }
    end
  end

  private

  def header
    div(class: "flex items-start justify-between gap-3") do
      div do
        p(class: "text-xs font-medium uppercase tracking-wide text-gray-600 dark:text-gray-300") do
          "Cycle progress · your org"
        end
        h2(class: "text-base font-semibold text-gray-900 dark:text-white") { @cycle.name }
      end
      span(class: "text-sm text-gray-600 dark:text-gray-300") { "#{@result.total} enrolled" }
    end
  end

  def mini_funnel
    div(class: "mt-3 flex items-center gap-2 text-xs font-medium") do
      stage("Self", @result.funnel.self_pct, "text-blue-600 dark:text-blue-400")
      arrow
      stage("Mgr", @result.funnel.manager_pct, "text-amber-700 dark:text-amber-400")
      arrow
      stage("Aligned", @result.funnel.aligned_pct, "text-green-700 dark:text-green-400")
    end
  end

  def stage(label, pct, color)
    span(class: color) { "#{label} #{pct}%" }
  end

  def arrow
    span(class: "text-gray-600 dark:text-gray-300") { "▸" }
  end

  def attention_line
    return if @result.at_risk_count.zero?

    lagging = @result.top_lagging_group
    p(class: "mt-3 text-sm text-amber-700 dark:text-amber-400") do
      plain "⚠ #{@result.at_risk_count} need attention"
      if lagging && lagging.at_risk_count.positive?
        span(class: "text-gray-600 dark:text-gray-300") { " · #{lagging.label} is behind" }
      end
    end
  end

  def view_link
    a(
      href: cohort_assessment_cycle_path(@cycle),
      data: { turbo_frame: "_top" },
      class: "inline-flex items-center min-h-11 text-sm font-medium text-primary hover:underline"
    ) { "View progress →" }
  end
end
