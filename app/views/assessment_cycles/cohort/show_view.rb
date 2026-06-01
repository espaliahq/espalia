# frozen_string_literal: true

# Cohort progress drill-down for an assessment cycle.
#
# Lead with the funnel (Self → Manager → Aligned, owned by different actors) and
# a "needs attention" list, then a grouped breakdown (by manager / role / level)
# and a participant list. Privacy: only lifecycle/completion is shown — never
# rating values or individual scores.
class Views::AssessmentCycles::Cohort::ShowView < Views::Base
  STATUS_VARIANTS = {
    "in_progress" => :default,
    "started" => :info,
    "self_complete" => :info,
    "manager_complete" => :info,
    "aligning" => :warning,
    "aligned" => :success
  }.freeze

  PIVOTS = { "manager" => "By manager", "role" => "By role", "level" => "By level" }.freeze

  # @param result [Reporting::CycleCohort::Result]
  # @param pivot [String] active grouping pivot ("manager" | "role" | "level")
  def initialize(result:, pivot: "manager", user: nil, current_tenant: nil, tenants: [])
    @result = result
    @pivot = pivot
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Kit::PageLayout.new(
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      div(class: "mx-auto max-w-5xl space-y-6") do
        header
        if @result.any?
          funnel_card
          needs_attention_card
          groups_card
          participants_card
        else
          empty_state
        end
      end
    end
  end

  private

  def cycle = @result.cycle

  def header
    div do
      a(href: assessment_cycles_path,
        class: "text-sm text-gray-500 hover:underline dark:text-gray-400") { "← Cycles" }
      div(class: "mt-1 flex flex-wrap items-baseline gap-x-3 gap-y-1") do
        h1(class: "text-2xl font-semibold text-gray-900 dark:text-white") { "#{cycle.name} — cohort progress" }
        span(class: "text-sm text-gray-500 dark:text-gray-400") { "#{@result.total} enrolled" }
        deadline_badge
      end
      p(class: "mt-2 text-xs text-gray-400 dark:text-gray-500") do
        "Ratings stay private to each person and their manager until alignment. This view shows progress only."
      end
    end
  end

  def deadline_badge
    return unless cycle.planned_end_at

    overdue = cycle.planned_end_at.to_time < Time.current
    label = overdue ? "Overdue · ended #{cycle.planned_end_at.to_fs(:long)}" : "Ends #{cycle.planned_end_at.to_fs(:long)}"
    render Components::Kit::Badge.new(label, variant: overdue ? :warning : :default)
  end

  def funnel_card
    render Components::Kit::Card.new(title: "Progress funnel") do |card|
      card.body do
        div(class: "space-y-3") do
          funnel_bar("Self-assessed", @result.funnel.self_done, @result.funnel.self_pct, "bg-blue-500")
          funnel_bar("Manager-assessed", @result.funnel.manager_done, @result.funnel.manager_pct, "bg-amber-500")
          funnel_bar("Aligned", @result.funnel.aligned, @result.funnel.aligned_pct, "bg-green-500")
        end
      end
    end
  end

  def funnel_bar(label, count, pct, color)
    div do
      div(class: "mb-1 flex items-baseline justify-between text-sm") do
        span(class: "font-medium text-gray-700 dark:text-gray-200") { label }
        span(class: "text-gray-500 dark:text-gray-400") { "#{count} of #{@result.total} · #{pct}%" }
      end
      div(class: "h-2 w-full overflow-hidden rounded-full bg-gray-100 dark:bg-gray-700") do
        div(class: "h-2 rounded-full #{color}", style: "width: #{pct}%")
      end
    end
  end

  def needs_attention_card
    at_risk = @result.participants.select(&:at_risk)
    render Components::Kit::Card.new(title: "Needs attention") do |card|
      card.body do
        if at_risk.empty?
          p(class: "text-sm text-gray-500 dark:text-gray-400") { "Nobody is flagged — the cohort is on track." }
        else
          p(class: "text-sm text-gray-700 dark:text-gray-200") do
            "#{at_risk.size} #{at_risk.size == 1 ? "participant is" : "participants are"} at risk (past the deadline or idle)."
          end
          ul(class: "mt-2 space-y-1") do
            at_risk.first(8).each do |participant|
              li(class: "text-sm text-gray-600 dark:text-gray-300") do
                plain participant.name
                span(class: "text-gray-400 dark:text-gray-500") { " · #{participant.role_name || "—"}" }
              end
            end
          end
        end
      end
    end
  end

  def groups_card
    render Components::Kit::Card.new(variant: :flush) do |card|
      card.body do
        div(class: "border-b border-gray-200 px-6 pt-5 dark:border-gray-700") do
          h3(class: "mb-3 text-base font-semibold text-gray-900 dark:text-white") { "Breakdown" }
          pivot_tabs
        end
        groups_table
      end
    end
  end

  def pivot_tabs
    nav(class: "flex gap-1", aria: { label: "Group by" }) do
      PIVOTS.each do |key, label|
        active = key == @pivot
        a(
          href: cohort_assessment_cycle_path(cycle, pivot: key),
          aria: { current: active ? "page" : nil },
          class: [
            "rounded-t-md px-3 py-2 text-sm font-medium",
            active ? "border-b-2 border-primary text-primary" : "text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200"
          ].join(" ")
        ) { label }
      end
    end
  end

  def groups_table
    groups = @result.groups[@pivot.to_sym] || []
    div(class: "divide-y divide-gray-100 dark:divide-gray-700") do
      groups.each { |group| group_row(group) }
    end
  end

  def group_row(group)
    div(class: "flex flex-wrap items-center justify-between gap-2 px-6 py-3") do
      div do
        span(class: "text-sm font-medium text-gray-900 dark:text-white") { group.label }
        span(class: "ml-2 text-xs text-gray-400 dark:text-gray-500") { "#{group.total} #{group.total == 1 ? "person" : "people"}" }
      end
      div(class: "flex items-center gap-3 text-xs text-gray-500 dark:text-gray-400") do
        span { "Aligned #{group.funnel.aligned_pct}%" }
        if group.at_risk_count.positive?
          render Components::Kit::Badge.new("#{group.at_risk_count} at risk", variant: :warning)
        end
      end
    end
  end

  def participants_card
    render Components::Kit::Card.new(variant: :flush) do |card|
      card.body do
        div(class: "px-6 pt-5") do
          h3(class: "mb-1 text-base font-semibold text-gray-900 dark:text-white") { "Participants" }
        end
        div(class: "mt-2 divide-y divide-gray-100 dark:divide-gray-700") do
          @result.participants.each { |participant| participant_row(participant) }
        end
      end
    end
  end

  def participant_row(participant)
    div(class: "flex flex-wrap items-center justify-between gap-2 px-6 py-3") do
      div do
        span(class: "text-sm font-medium text-gray-900 dark:text-white") { participant.name }
        span(class: "ml-2 text-xs text-gray-400 dark:text-gray-500") do
          [ participant.role_name, participant.level_ordinal && "L#{participant.level_ordinal}" ].compact.join(" · ")
        end
      end
      div(class: "flex items-center gap-2") do
        coverage_chip("Self", participant.self_done)
        coverage_chip("Mgr", participant.manager_done)
        status_badge(participant)
        render(Components::Kit::Badge.new("At risk", variant: :warning)) if participant.at_risk
      end
    end
  end

  def coverage_chip(label, done)
    classes = done ? "bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400" : "bg-gray-100 text-gray-500 dark:bg-gray-700 dark:text-gray-400"
    span(class: "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium #{classes}") do
      "#{label} #{done ? "✓" : "—"}"
    end
  end

  def status_badge(participant)
    variant = STATUS_VARIANTS.fetch(participant.status, :default)
    render Components::Kit::Badge.new(participant.status.humanize, variant: variant)
  end

  def empty_state
    render Components::Kit::Card.new do |card|
      card.body do
        p(class: "text-sm text-gray-500 dark:text-gray-400") { "No participants in your scope for this cycle yet." }
      end
    end
  end
end
