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
  # @param scope [String] active viewer scope ("all" | "mine")
  # @param can_scope_to_self [Boolean] whether to offer the My-org/Whole-cycle toggle
  # @param viewable_assignments [Hash{String => PersonFrameworkAssignment}]
  #   person_id → assignment for participants whose assessment the viewer may
  #   open — their names render as links to the assessment
  def initialize(result:, pivot: "manager", scope: "all", can_scope_to_self: false,
                 viewable_assignments: {}, user: nil, current_tenant: nil, tenants: [])
    @result = result
    @pivot = pivot
    @scope = scope
    @can_scope_to_self = can_scope_to_self
    @viewable_assignments = viewable_assignments
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Shell::PageLayout.new(
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
        class: "inline-flex min-h-11 items-center text-sm text-muted hover:underline") { "← Cycles" }
      div(class: "mt-1 flex flex-wrap items-baseline gap-x-3 gap-y-1") do
        h1(class: "text-2xl font-semibold text-default") { "#{cycle.name} — cohort progress" }
        span(class: "text-sm text-muted") { "#{@result.total} enrolled" }
        deadline_badge
        a(href: attainment_assessment_cycle_path(cycle),
          class: "inline-flex min-h-11 items-center text-sm text-link hover:text-link-hover hover:underline") { "Capability attainment →" }
        a(href: evidence_assessment_cycle_path(cycle),
          class: "inline-flex min-h-11 items-center text-sm text-link hover:text-link-hover hover:underline") { "Feedback & evidence →" }
      end
      p(class: "mt-2 text-xs text-muted") do
        "Ratings stay private to each person and their manager until alignment. This view shows progress only."
      end
      scope_toggle
    end
  end

  # Admin/HR who are also managers can flip between the whole cycle and just
  # their own org subtree.
  def scope_toggle
    return unless @can_scope_to_self

    render Components::Kit::SegmentedControl.new(label: "Scope", class: "mt-3") do |control|
      scope_link(control, "Whole cycle", "all")
      scope_link(control, "My org", "mine")
    end
  end

  def scope_link(control, label, value)
    params = { pivot: @pivot }
    params[:scope] = value if value == "mine"
    control.segment(label, href: cohort_assessment_cycle_path(cycle, **params), selected: @scope == value)
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
          funnel_bar("Self-assessed", @result.funnel.self_done, @result.funnel.self_pct, "bg-progress-self")
          funnel_bar("Manager-assessed", @result.funnel.manager_done, @result.funnel.manager_pct, "bg-progress-manager")
          funnel_bar("Aligned", @result.funnel.aligned, @result.funnel.aligned_pct, "bg-progress-aligned")
        end
      end
    end
  end

  def funnel_bar(label, count, pct, color)
    div do
      div(class: "mb-1 flex items-baseline justify-between text-sm") do
        span(class: "font-medium text-muted") { label }
        span(class: "text-muted") { "#{count} of #{@result.total} · #{pct}%" }
      end
      div(
        class: "h-2 w-full overflow-hidden rounded-full bg-neutral-subtle",
        role: "progressbar",
        aria: {
          label: "#{label}: #{count} of #{@result.total} (#{pct}%)",
          valuenow: pct, valuemin: 0, valuemax: 100
        }
      ) do
        div(class: "h-2 rounded-full #{color}", style: "width: #{pct}%")
      end
    end
  end

  def needs_attention_card
    at_risk = @result.participants.select(&:at_risk)
    render Components::Kit::Card.new(title: "Needs attention") do |card|
      card.body do
        if at_risk.empty?
          p(class: "text-sm text-muted") { "Nobody is flagged — the cohort is on track." }
        else
          p(class: "text-sm text-muted") do
            "#{at_risk.size} #{at_risk.size == 1 ? "participant is" : "participants are"} at risk (past the deadline or idle)."
          end
          ul(class: "mt-2 space-y-1") do
            at_risk.first(8).each do |participant|
              li(class: "text-sm text-muted") do
                participant_name(participant)
                span(class: "text-muted") { " · #{participant.role_name || "—"}" }
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
        div(class: "border-b border-default px-6 pt-5") do
          h3(class: "mb-3 text-base font-semibold text-default") { "Breakdown" }
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
          href: cohort_assessment_cycle_path(cycle, **pivot_link_params(key)),
          aria: { current: active ? "page" : nil },
          class: [
            "rounded-t-md px-3 py-2 text-sm font-medium",
            active ? "border-b-2 border-strong text-default" : "text-muted hover:text-default"
          ].join(" ")
        ) { label }
      end
    end
  end

  # Preserve the active scope when switching pivots.
  def pivot_link_params(key)
    params = { pivot: key }
    params[:scope] = "mine" if @scope == "mine"
    params
  end

  def groups_table
    groups = @result.groups[@pivot.to_sym] || []
    div(class: "divide-y divide-subtle") do
      groups.each { |group| group_row(group) }
    end
  end

  def group_row(group)
    div(class: "flex flex-wrap items-center justify-between gap-2 px-6 py-3") do
      div do
        span(class: "text-sm font-medium text-default") { group.label }
        span(class: "ml-2 text-xs text-muted") { "#{group.total} #{group.total == 1 ? "person" : "people"}" }
      end
      div(class: "flex items-center gap-3 text-xs text-muted") do
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
          h3(class: "mb-1 text-base font-semibold text-default") { "Participants" }
        end
        div(class: "mt-2 divide-y divide-subtle") do
          @result.participants.each { |participant| participant_row(participant) }
        end
      end
    end
  end

  def participant_row(participant)
    div(class: "flex flex-wrap items-center justify-between gap-2 px-6 py-3") do
      div do
        span(class: "text-sm font-medium text-default") { participant_name(participant) }
        span(class: "ml-2 text-xs text-muted") do
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

  # The name links to the participant's assessment when the viewer may open it
  # (AssessmentPolicy#show?, resolved in bulk by the controller); otherwise it
  # renders as plain text. The cohort itself stays lifecycle-only — the link is
  # the drill-down for viewers who could already open the assessment anyway.
  def participant_name(participant)
    assignment = @viewable_assignments[participant.person_id]
    if assignment
      a(href: assessment_path(assignment), class: "text-link hover:text-link-hover hover:underline") { participant.name }
    else
      plain participant.name
    end
  end

  def coverage_chip(label, done)
    render Components::Kit::Badge.new("#{label} #{done ? "✓" : "—"}", tone: done ? :success : :neutral)
  end

  def status_badge(participant)
    variant = STATUS_VARIANTS.fetch(participant.status, :default)
    render Components::Kit::Badge.new(participant.status.humanize, variant: variant)
  end

  def empty_state
    render Components::Kit::Card.new do |card|
      card.body do
        p(class: "text-sm text-muted") { "No participants in your scope for this cycle yet." }
      end
    end
  end
end
