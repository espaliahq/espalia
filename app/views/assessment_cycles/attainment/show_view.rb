# frozen_string_literal: true

# Capability attainment heatmap for an assessment cycle.
#
# Rows are categories → capabilities; columns are roles (grouped under their
# family) or role families. Each cell shows the share of people at or above
# their assessed level plus assessed coverage — coverage matters because an
# unrated capability buckets as "below", so a low % on thin coverage means
# "not assessed yet", not "failing". Category rows show the share passing the
# existing category gate. Suppressed cells (small cohorts, subtree-scoped
# viewers only) render as a muted "n < floor" marker with counts, no values.
class Views::AssessmentCycles::Attainment::ShowView < Views::Base
  PERSPECTIVES = {
    "effective" => "Effective",
    "self" => "Self",
    "manager" => "Manager",
    "aligned" => "Aligned"
  }.freeze

  BY_TABS = { "role" => "By role", "family" => "By role family" }.freeze

  # @param result [Reporting::CapabilityAttainment::Result]
  # @param perspective [String] active perspective param key
  # @param by [String] column axis ("role" | "family")
  # @param scope [String] active viewer scope ("all" | "mine")
  # @param can_scope_to_self [Boolean] whether to offer the My-org/Whole-cycle toggle
  def initialize(result:, perspective: "effective", by: "role", scope: "all",
                 can_scope_to_self: false, user: nil, current_tenant: nil, tenants: [])
    @result = result
    @perspective = perspective
    @by = by
    @scope = scope
    @can_scope_to_self = can_scope_to_self
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
        if @result.any?
          heatmap_card
        else
          empty_state
        end
      end
    end
  end

  private

  def cycle = @result.cycle

  def groups = @by == "family" ? @result.families : @result.roles

  def header
    div do
      a(href: assessment_cycle_path(cycle),
        class: "text-sm text-gray-500 hover:underline dark:text-gray-400") { "← #{cycle.name}" }
      div(class: "mt-1 flex flex-wrap items-baseline gap-x-3 gap-y-1") do
        h1(class: "text-2xl font-semibold text-gray-900 dark:text-white") { "#{cycle.name} — capability attainment" }
        span(class: "text-sm text-gray-600 dark:text-gray-300") do
          "#{@result.total_people} #{@result.total_people == 1 ? "person" : "people"}"
        end
      end
      p(class: "mt-2 text-xs text-gray-600 dark:text-gray-300") do
        "Share of people at or above their assessed level per capability, under the " \
          "#{PERSPECTIVES.fetch(@perspective).downcase} rating perspective. " \
          "Unassessed capabilities count as below — read the % together with its assessed coverage."
      end
      suppression_note
      div(class: "mt-3 flex flex-wrap items-center gap-3") do
        perspective_tabs
        by_tabs
        scope_toggle
      end
    end
  end

  def suppression_note
    return unless @result.suppression_floor

    p(class: "mt-1 text-xs text-gray-600 dark:text-gray-300") do
      "Groups smaller than #{@result.suppression_floor} people show coverage only, to avoid " \
        "exposing individual assessments."
    end
  end

  def perspective_tabs
    nav(class: "inline-flex gap-1 rounded-md bg-gray-100 p-0.5 dark:bg-gray-800", aria: { label: "Rating perspective" }) do
      PERSPECTIVES.each do |key, label|
        segment_link(label, attainment_path(perspective: key), active: key == @perspective)
      end
    end
  end

  def by_tabs
    nav(class: "inline-flex gap-1 rounded-md bg-gray-100 p-0.5 dark:bg-gray-800", aria: { label: "Column axis" }) do
      BY_TABS.each do |key, label|
        segment_link(label, attainment_path(by: key), active: key == @by)
      end
    end
  end

  # Admin/HR who are also managers can flip between the whole cycle and just
  # their own org subtree.
  def scope_toggle
    return unless @can_scope_to_self

    nav(class: "inline-flex gap-1 rounded-md bg-gray-100 p-0.5 dark:bg-gray-800", aria: { label: "Scope" }) do
      segment_link("Whole cycle", attainment_path(scope: nil), active: @scope == "all")
      segment_link("My org", attainment_path(scope: "mine"), active: @scope == "mine")
    end
  end

  def segment_link(label, href, active:)
    a(
      href: href,
      aria: { current: active ? "true" : nil },
      class: [
        "rounded px-3 py-1 text-sm font-medium",
        active ? "bg-white text-gray-900 shadow-xs dark:bg-gray-700 dark:text-white" : "text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200"
      ].join(" ")
    ) { label }
  end

  # Builds the report path preserving the other axes.
  def attainment_path(perspective: @perspective, by: @by, scope: @scope)
    params = {}
    params[:perspective] = perspective if perspective && perspective != "effective"
    params[:by] = by if by && by != "role"
    params[:scope] = "mine" if scope == "mine"
    attainment_assessment_cycle_path(cycle, **params)
  end

  def heatmap_card
    render Components::Kit::Card.new(variant: :flush) do |card|
      card.body do
        div(class: "overflow-x-auto") do
          table(class: "w-full min-w-max border-collapse text-sm") do
            caption(class: "sr-only") { "Capability attainment by #{@by == "family" ? "role family" : "role"}" }
            heatmap_head
            heatmap_body
          end
        end
      end
    end
  end

  def heatmap_head
    thead do
      tr(class: "border-b border-gray-200 dark:border-gray-700") do
        th(class: "px-4 py-3 text-left font-medium text-gray-500 dark:text-gray-400", scope: "col") { "Capability" }
        groups.each do |group|
          th(class: "px-3 py-3 text-center align-bottom", scope: "col") do
            div(class: "text-sm font-semibold text-gray-900 dark:text-white") { group.label }
            if @by == "role"
              div(class: "text-xs font-normal text-gray-500 dark:text-gray-400") { family_name(group.family_key) }
            end
            div(class: "text-xs font-normal text-gray-500 dark:text-gray-400") do
              "#{group.n_people} #{group.n_people == 1 ? "person" : "people"}"
            end
          end
        end
      end
    end
  end

  def heatmap_body
    tbody do
      @result.categories.each do |category|
        rows = @result.capabilities.select { |cap| cap.category_id == category.category_id }
        next if rows.empty?

        category_row(category)
        rows.each { |capability| capability_row(capability) }
      end
    end
  end

  def category_row(category)
    tr(class: "border-b border-gray-200 bg-gray-50 dark:border-gray-700 dark:bg-gray-800/60") do
      th(class: "px-4 py-2 text-left text-xs font-semibold tracking-wide text-gray-700 uppercase dark:text-gray-200", scope: "row") do
        category.name
      end
      groups.each do |group|
        td(class: "px-3 py-2 text-center") do
          category_cell(group.category_cells[category.category_id])
        end
      end
    end
  end

  def category_cell(cell)
    return em_dash unless cell

    if cell.suppressed
      suppressed_marker(cell.n_in_group)
    else
      span(class: "text-xs font-medium text-gray-700 dark:text-gray-200") { "#{cell.pass_pct}% pass" }
    end
  end

  def capability_row(capability)
    tr(class: "border-b border-gray-100 dark:border-gray-700/60") do
      th(class: "max-w-56 px-4 py-2 text-left font-normal text-gray-900 dark:text-white", scope: "row") do
        capability.name
      end
      groups.each do |group|
        td(class: "px-3 py-2 text-center") { attainment_cell(group.cells[capability.stable_id]) }
      end
    end
  end

  def attainment_cell(cell)
    return em_dash unless cell

    if cell.suppressed
      div do
        suppressed_marker(cell.n_in_group)
        coverage_line(cell)
      end
    else
      div do
        span(class: "inline-flex min-w-14 items-center justify-center rounded-md px-2 py-0.5 text-sm font-semibold #{pct_classes(cell)}") do
          "#{cell.at_or_above_pct}%"
        end
        coverage_line(cell)
      end
    end
  end

  def coverage_line(cell)
    div(class: "mt-0.5 text-xs text-gray-500 dark:text-gray-400") do
      "#{cell.n_assessed}/#{cell.n_in_group} assessed"
    end
  end

  def family_name(family_key)
    @family_names ||= @result.families.to_h { |family| [ family.key, family.label ] }
    @family_names[family_key]
  end

  # Not applicable — the capability isn't bound to any role in this column.
  def em_dash
    span(class: "text-gray-300 dark:text-gray-600") { "—" }
  end

  def suppressed_marker(n_in_group)
    span(
      class: "inline-flex items-center rounded-md bg-gray-100 px-2 py-0.5 text-xs font-medium text-gray-500 dark:bg-gray-700 dark:text-gray-300",
      title: "Fewer than #{@result.suppression_floor} people — values hidden to avoid exposing individual assessments"
    ) { "n = #{n_in_group}" }
  end

  # Heatmap tint tiers for the at-or-above share. A cell nobody has been
  # assessed on yet stays neutral — "not yet assessed" must not read as
  # "failing" (the 0% only reflects the below-by-default rule).
  def pct_classes(cell)
    return "bg-gray-100 text-gray-500 dark:bg-gray-700 dark:text-gray-300" if cell.n_assessed.zero?

    pct = cell.at_or_above_pct
    if pct >= 80
      "bg-green-100 text-green-800 dark:bg-green-900/40 dark:text-green-300"
    elsif pct >= 60
      "bg-lime-100 text-lime-800 dark:bg-lime-900/40 dark:text-lime-300"
    elsif pct >= 40
      "bg-amber-100 text-amber-800 dark:bg-amber-900/40 dark:text-amber-300"
    else
      "bg-red-100 text-red-800 dark:bg-red-900/40 dark:text-red-300"
    end
  end

  def empty_state
    render Components::Kit::Card.new do |card|
      card.body do
        p(class: "text-sm text-gray-600 dark:text-gray-300") { "No participants in your scope for this cycle yet." }
      end
    end
  end
end
