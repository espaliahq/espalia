# frozen_string_literal: true

# Aggregate feedback / evidence coverage for an assessment cycle. Counts unique
# evidence items, not capability links, and keeps request fulfilment separate
# from feedback provision so reused historical evidence cannot inflate totals.
class Views::AssessmentCycles::EvidenceReport::ShowView < Views::Base
  GROUPS = {
    "manager" => "By manager",
    "role" => "By role",
    "level" => "By level"
  }.freeze

  # @param cycle [AssessmentCycle]
  # @param report [Hash] serialized Operations::Reporting::EvidenceCoverage output
  # @param group_by [String] active grouping (manager | role | level)
  # @param scope [String] active scope (all | mine)
  # @param can_scope_to_self [Boolean] whether to show the scope switcher
  # @param can_export_feedback [Boolean] whether to offer the feedback CSV
  #   (tenant admins only — it carries names and content this report never shows)
  #
  # The active month and the months on offer are read from the report itself
  # (`period` / `available_months`), so the view and the MCP payload can't
  # disagree about which window the counts describe.
  def initialize(cycle:, report:, group_by: "manager", scope: "all",
                 can_scope_to_self: false, can_export_feedback: false,
                 user: nil, current_tenant: nil, tenants: [])
    @cycle = cycle
    @report = report
    @group_by = group_by
    @scope = scope
    @can_scope_to_self = can_scope_to_self
    @can_export_feedback = can_export_feedback
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Kit::PageLayout.new(
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      div(class: "mx-auto max-w-6xl space-y-6") do
        header
        if metrics[:participant_count].positive?
          summary_grid
          directionality_card
          reporting_note
          breakdown_card
        else
          empty_state
        end
      end
    end
  end

  private

  def metrics = @report[:metrics]

  def directionality = metrics[:feedback_directionality]

  def groups = @report.dig(:groups, @group_by.to_sym) || []

  def period = @report[:period]

  def available_months = @report[:available_months] || []

  def month_key = period&.dig(:month)

  def header
    div do
      a(
        href: assessment_cycle_path(@cycle),
        class: "inline-flex min-h-11 items-center text-sm text-gray-600 hover:underline dark:text-gray-300"
      ) { "← #{@cycle.name}" }
      div(class: "flex flex-wrap items-baseline gap-x-3 gap-y-1") do
        h1(class: "text-2xl font-semibold text-gray-900 dark:text-white") do
          "#{@cycle.name} — feedback & evidence"
        end
        span(class: "text-sm text-gray-600 dark:text-gray-300") do
          participant_label(metrics[:participant_count])
        end
      end
      p(class: "mt-2 max-w-3xl text-sm text-gray-600 dark:text-gray-300") do
        if period
          "Feedback recorded and requests sent in #{period[:label]}, whether requested or proactive, " \
            "alongside the request response funnel."
        else
          "Feedback provided during this cycle, whether requested or proactive, alongside the request response funnel."
        end
      end
      report_navigation
      div(class: "mt-3 flex flex-wrap items-center gap-3") do
        group_tabs
        scope_toggle
        month_filter
        csv_download
      end
    end
  end

  # The whole cycle's feedback for the month on screen, whatever the scope or
  # grouping: the export is per cycle, so under "My org" the label says so. A
  # full navigation, since Turbo can't hand a file to the browser.
  def csv_download
    return unless @can_export_feedback

    a(
      href: tenant_feedback_exports_path(format: :csv, cycle_id: @cycle.cycle_id, month: month_key),
      class: Components::Kit::FrameLoadError::BUTTON_CLASSES,
      data: { turbo: "false" }
    ) { @scope == "mine" ? "Download CSV (whole cycle)" : "Download CSV" }
  end

  # Narrow the report to one month of the cycle. A plain GET form with an
  # explicit Apply (no submit-on-change) so changing the select never moves
  # the page out from under a keyboard or screen-reader user.
  def month_filter
    return if available_months.empty?

    form(
      action: evidence_assessment_cycle_path(@cycle), method: "get",
      class: "flex flex-wrap items-center gap-2"
    ) do
      carried_params(month: nil).each { |name, value| input(type: "hidden", name: name, value: value) }
      label(
        for: "evidence-report-month",
        class: "text-sm font-medium text-gray-600 dark:text-gray-300"
      ) { "Month" }
      select(
        id: "evidence-report-month", name: "month",
        class: "min-h-11 min-w-40 rounded-md border border-gray-300 bg-white px-2 text-sm text-gray-900 " \
               "dark:border-gray-600 dark:bg-gray-800 dark:text-white"
      ) do
        option(value: "", selected: month_key.nil?) { "Whole cycle" }
        available_months.each do |candidate|
          option(value: candidate[:month], selected: candidate[:month] == month_key) { candidate[:label] }
        end
      end
      button(type: "submit", class: Components::Kit::FrameLoadError::BUTTON_CLASSES) { "Apply" }
    end
  end

  def report_navigation
    nav(class: "mt-2 flex flex-wrap gap-x-4 gap-y-1", aria: { label: "Assessment cycle reports" }) do
      a(
        href: cohort_assessment_cycle_path(@cycle),
        class: "inline-flex min-h-11 items-center text-sm text-primary-ink hover:underline"
      ) { "Cohort progress" }
      a(
        href: attainment_assessment_cycle_path(@cycle),
        class: "inline-flex min-h-11 items-center text-sm text-primary-ink hover:underline"
      ) { "Capability attainment" }
    end
  end

  def group_tabs
    nav(
      class: "flex flex-wrap gap-1 rounded-md bg-gray-100 p-0.5 dark:bg-gray-800",
      aria: { label: "Group feedback coverage" }
    ) do
      GROUPS.each do |key, label|
        segment_link(label, report_path(group: key), active: key == @group_by)
      end
    end
  end

  def scope_toggle
    return unless @can_scope_to_self

    nav(
      class: "inline-flex gap-1 rounded-md bg-gray-100 p-0.5 dark:bg-gray-800",
      aria: { label: "Scope" }
    ) do
      segment_link("Whole cycle", report_path(scope: nil), active: @scope == "all")
      segment_link("My org", report_path(scope: "mine"), active: @scope == "mine")
    end
  end

  def segment_link(label, href, active:)
    a(
      href: href,
      aria: { current: active ? "page" : nil },
      class: [
        "inline-flex min-h-11 items-center rounded px-3 py-1 text-sm font-medium",
        active ? "bg-white text-gray-900 shadow-xs dark:bg-gray-700 dark:text-white" :
          "text-gray-600 hover:text-gray-900 dark:text-gray-300 dark:hover:text-white"
      ].join(" ")
    ) { label }
  end

  def report_path(group: @group_by, scope: @scope)
    evidence_assessment_cycle_path(@cycle, **carried_params(group: group, scope: scope))
  end

  # The filter params a link or form must carry so switching one axis keeps
  # the others; defaults are omitted to keep URLs clean.
  def carried_params(group: @group_by, scope: @scope, month: month_key)
    {
      group: (group if group && group != "manager"),
      scope: ("mine" if scope == "mine"),
      month: month
    }.compact
  end

  def summary_grid
    div(class: "grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4") do
      feedback_card
      participant_coverage_card
      requests_card
      fulfillment_card
    end
  end

  def directionality_card
    render Components::Kit::Card.new(title: "Feedback direction", heading_level: :h2) do |card|
      card.body do
        p(class: "text-sm text-gray-600 dark:text-gray-300") do
          "How interpersonal feedback moved through this reporting scope."
        end

        if directionality[:interpersonal_total].positive?
          div(class: "mt-5 grid gap-4 md:grid-cols-2") do
            direction_row(
              "Manager → report",
              directionality[:manager_to_report],
              directionality[:manager_to_report_pct]
            )
            direction_row(
              "Peer → peer",
              directionality[:peer_to_peer],
              directionality[:peer_to_peer_pct]
            )
            direction_row(
              "Report → manager",
              directionality[:report_to_manager],
              directionality[:report_to_manager_pct]
            )
            if directionality[:legacy_peer_or_upward].positive?
              direction_row(
                "Peer → peer or report → manager (historical)",
                directionality[:legacy_peer_or_upward],
                directionality[:legacy_peer_or_upward_pct]
              )
            end
          end
        else
          p(class: "mt-4 text-sm text-gray-600 dark:text-gray-300") do
            "No interpersonal feedback was provided in this scope."
          end
        end

        div(class: "mt-5 flex items-baseline justify-between gap-3 border-t border-gray-200 pt-4 dark:border-gray-700") do
          span(class: "text-sm text-gray-600 dark:text-gray-300") { "Self-provided feedback" }
          span(class: "font-semibold text-gray-900 dark:text-white") do
            directionality[:self_provided].to_s
          end
        end

        if directionality[:legacy_peer_or_upward].positive?
          p(class: "mt-3 text-xs text-gray-500 dark:text-gray-400") do
            "Historical peer-source feedback cannot be split reliably, so it remains in a combined peer-or-upward bucket."
          end
        end
      end
    end
  end

  def direction_row(label, count, percent)
    div(class: "min-w-0 rounded-lg border border-gray-200 bg-gray-50 p-4 dark:border-gray-700 dark:bg-gray-800/50") do
      div(class: "flex items-start justify-between gap-3 text-sm") do
        span(class: "font-medium text-gray-800 dark:text-gray-100") { label }
        span(class: "shrink-0 tabular-nums text-gray-600 dark:text-gray-300") { "#{count} (#{percent}%)" }
      end
      div(
        class: "mt-2 h-2 w-full overflow-hidden rounded-full bg-gray-100 dark:bg-gray-700",
        role: "progressbar",
        aria: {
          label: "#{label}: #{count} feedback items, #{percent}% of interpersonal feedback",
          valuenow: percent,
          valuemin: 0,
          valuemax: 100
        }
      ) do
        div(
          class: "h-2 rounded-full bg-blue-600",
          style: "width: #{percent}%"
        )
      end
    end
  end

  def feedback_card
    render Components::Kit::Card.new(title: "Feedback provided", heading_level: :h2) do |card|
      card.body do
        metric_value(metrics[:feedback_provided])
        dl(class: "mt-4 space-y-2 text-sm") do
          metric_row("By request", metrics[:provided_by_request])
          metric_row("Proactive", metrics[:provided_unsolicited])
          metric_row("Withdrawn", metrics[:feedback_withdrawn])
        end
      end
    end
  end

  def participant_coverage_card
    render Components::Kit::Card.new(title: "Participant coverage", heading_level: :h2) do |card|
      card.body do
        metric_value("#{metrics[:participant_coverage_pct]}%")
        p(class: "mt-1 text-sm text-gray-600 dark:text-gray-300") do
          "#{metrics[:participants_with_feedback]} of #{metrics[:participant_count]} participants have feedback"
        end
        progress_bar(
          metrics[:participant_coverage_pct],
          "Participant feedback coverage: #{metrics[:participant_coverage_pct]}%"
        )
      end
    end
  end

  def requests_card
    render Components::Kit::Card.new(title: "Requests sent", heading_level: :h2) do |card|
      card.body do
        metric_value(metrics[:requests_sent])
        dl(class: "mt-4 grid grid-cols-2 gap-x-4 gap-y-2 text-sm") do
          metric_row("Fulfilled", metrics[:requests_fulfilled])
          metric_row("Awaiting", metrics[:requests_pending])
          metric_row("Declined", metrics[:requests_declined])
          metric_row("Cancelled", metrics[:requests_cancelled])
        end
      end
    end
  end

  def fulfillment_card
    render Components::Kit::Card.new(title: "Request fulfilment", heading_level: :h2) do |card|
      card.body do
        metric_value("#{metrics[:request_fulfillment_pct]}%")
        denominator = metrics[:requests_sent] - metrics[:requests_cancelled]
        p(class: "mt-1 text-sm text-gray-600 dark:text-gray-300") do
          "#{metrics[:requests_fulfilled]} of #{denominator} non-cancelled requests fulfilled"
        end
        progress_bar(
          metrics[:request_fulfillment_pct],
          "Request fulfilment: #{metrics[:request_fulfillment_pct]}%"
        )
      end
    end
  end

  def metric_value(value)
    p(class: "text-3xl font-semibold tracking-tight text-gray-900 dark:text-white") { value.to_s }
  end

  def metric_row(label, value)
    div(class: "flex items-baseline justify-between gap-3") do
      dt(class: "text-gray-600 dark:text-gray-300") { label }
      dd(class: "font-semibold text-gray-900 dark:text-white") { value.to_s }
    end
  end

  def progress_bar(percent, label)
    div(
      class: "mt-4 h-2 w-full overflow-hidden rounded-full bg-gray-100 dark:bg-gray-700",
      role: "progressbar",
      aria: { label: label, valuenow: percent, valuemin: 0, valuemax: 100 }
    ) do
      div(class: "h-2 rounded-full bg-blue-600", style: "width: #{percent}%")
    end
  end

  def reporting_note
    p(class: "text-sm text-gray-600 dark:text-gray-300") do
      plain "Counts are based on unique feedback items first provided for this cycle. " \
        "Relinking existing evidence does not count it again. Withdrawn feedback is shown separately."
      if period
        plain " #{period[:label]} counts feedback by when it was recorded (including withdrawn items, " \
          "whenever they were withdrawn) and requests by when they were sent, with their current status. " \
          "The two windows differ: feedback answering an earlier month's request counts here as by request, " \
          "while the request itself counts in the month it was sent."
      end
    end
  end

  def breakdown_card
    render Components::Kit::Card.new(variant: :flush) do |card|
      card.body do
        div(class: "px-6 pt-5") do
          h2(class: "text-base font-semibold text-gray-900 dark:text-white") { "Breakdown" }
        end
        div(class: "mt-3 overflow-x-auto") do
          table(class: "w-full min-w-190 border-collapse text-sm") do
            caption(class: "sr-only") { "Feedback and evidence coverage #{GROUPS.fetch(@group_by).downcase}" }
            breakdown_head
            tbody(class: "divide-y divide-gray-100 dark:divide-gray-700") do
              groups.each { |group| breakdown_row(group) }
            end
          end
        end
      end
    end
  end

  def breakdown_head
    thead do
      tr(class: "border-y border-gray-200 bg-gray-50 dark:border-gray-700 dark:bg-gray-900") do
        table_heading(GROUPS.fetch(@group_by).delete_prefix("By ").capitalize, align: :left)
        table_heading("People")
        table_heading("Provided")
        table_heading("By request")
        table_heading("Proactive")
        table_heading("Requests")
        table_heading("Awaiting")
        table_heading("Coverage")
      end
    end
  end

  def table_heading(label, align: :right)
    th(
      scope: "col",
      class: "px-4 py-3 #{align == :left ? "text-left" : "text-right"} font-medium text-gray-600 dark:text-gray-300"
    ) { label }
  end

  def breakdown_row(group)
    row = group[:metrics]
    tr do
      th(scope: "row", class: "px-4 py-3 text-left font-medium text-gray-900 dark:text-white") do
        group[:label]
      end
      table_value(row[:participant_count])
      table_value(row[:feedback_provided])
      table_value(row[:provided_by_request])
      table_value(row[:provided_unsolicited])
      table_value(row[:requests_sent])
      table_value(row[:requests_pending])
      table_value("#{row[:participant_coverage_pct]}%")
    end
  end

  def table_value(value)
    td(class: "px-4 py-3 text-right text-gray-700 dark:text-gray-200") { value.to_s }
  end

  def empty_state
    render Components::Kit::Card.new(title: "No participants", heading_level: :h2) do |card|
      card.body do
        p(class: "text-sm text-gray-600 dark:text-gray-300") do
          "There are no participants in your reporting scope for this cycle."
        end
      end
    end
  end

  def participant_label(count)
    "#{count} #{count == 1 ? "participant" : "participants"}"
  end
end
