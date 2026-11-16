# frozen_string_literal: true

# A plan's Budget tab ([#395](https://github.com/espaliahq/espalia/issues/395)).
# Today has no period, so it lists the lines as the organisation approved
# them. A scenario shows `team_planning_budget`'s four numbers, each line's
# figures, and the positions `team_planning_funding` draws on it. Every figure
# is the read's, only formatted here, so this page and an agent never
# disagree. A budget amount is pay, so a member without the see-pay right
# sees head counts only ([#367](https://github.com/espaliahq/espalia/issues/367)).
class Views::Plans::BudgetTab < Views::Base
  include Views::Plans::ScenarioTab
  include Views::Tenant::BudgetLines::LineText

  DRAWS = { "filled" => "Filled", "backfill" => "Replaces a leaver", "open" => "Open" }.freeze

  # @param plan [Hash] from `team_planning_plan`
  # @param scenarios [Array<Hash>] from `team_planning_scenarios`, baseline first
  # @param lines [Hash] from `team_planning_budget_lines`
  # @param budget [Hash, nil] from `team_planning_budget`; nil on Today
  # @param funding [Hash, nil] from `team_planning_funding`; nil on Today
  # @param map [Hash, nil] from `team_planning_scenario_map`, for position and unit names; nil on Today
  # @param can_edit [Boolean] whether the viewer may change this scenario's lines and funding
  # @param funded_here [Set<String>] the positions whose funding this scenario sets itself
  def initialize(plan:, scenarios:, lines:, budget: nil, funding: nil, map: nil, can_edit: false, funded_here: Set.new)
    @plan = plan
    @scenarios = scenarios
    @lines = lines
    @budget = budget
    @funding = funding
    @map = map
    @can_edit = can_edit
    @funded_here = funded_here
  end

  def view_template
    section(aria: { labelledby: "budget-heading" }, class: "space-y-6", data: { budget_tab: scenario_id }) do
      div do
        h3(id: "budget-heading", class: "text-base font-semibold text-default") { "Budget on #{scenario_name(scenario_id)}" }
        @budget ? p(class: "mt-1 text-sm text-muted", data: { budget_basis: "" }) { basis } : today_note
        p(class: "mt-1 text-sm text-muted", data: { budget_no_money: "" }) { "Budget amounts show only to members who may see pay." } unless money?
        scenario_picker(path: :budget_plan_path, select_id: "budget-scenario")
      end
      if (note = (@budget || @lines)[:note])
        render Components::Kit::Alert.new(tone: :info) { note }
      end
      scope_note
      @budget ? scenario_budget : approved_lines
    end
  end

  private

  def plan_id = @plan[:plan_id]

  def scenario_id = @lines[:scenario_id]

  def reference = @budget[:reference_currency]

  def money? = (@budget || @lines)[:money] != false

  def today_note
    p(class: "mt-1 text-sm text-muted", data: { budget_today: "" }) do
      plain "The lines as the organisation approved them. What each scenario funds is worked out for its own period"
      others = @scenarios.reject { it[:scenario_id] == plan_id }
      if others.any?
        plain ": "
        others.each_with_index do |scenario, index|
          plain ", " if index.positive?
          a(href: budget_plan_path(plan_id, scenario: scenario[:scenario_id]), class: "text-link underline hover:text-link-hover") { scenario_name(scenario[:scenario_id]) }
        end
      end
      plain "."
    end
  end

  # A scoped plan holds only these lines ([#378](https://github.com/espaliahq/espalia/issues/378)).
  def scope_note
    return if @plan.dig(:scope, :whole_organisation) != false

    p(class: "text-sm text-muted", data: { budget_scope: "" }) { "Totals cover the budget lines this plan's seats can draw on." }
  end

  def approved_lines
    if @lines[:budget_lines].empty?
      render Components::Kit::EmptyState.new(title: "No budget lines yet.", size: :panel)
    else
      ul(class: "divide-y divide-default rounded-lg border border-default bg-default") do
        @lines[:budget_lines].each do |line|
          li(class: "space-y-1 p-3", data: { budget_line: line[:budget_line_id] }) do
            p(class: "text-sm font-medium text-default break-words") { line_name(line) }
            p(class: "text-sm text-default") { money? ? figures_text(line) : head_count_only(line[:head_count]) }
            p(class: "text-xs text-muted break-words") { terms_text(line) }
          end
        end
      end
    end
  end

  def basis
    period = @budget[:period]
    return "For #{Views::Plans::ScenarioTable.figured(period)}." unless money?

    on = @budget[:basis] == "inclusive" ? "base pay plus on-cost" : "base pay alone"
    priced = @budget[:pay_view] == "band_midpoints" ? "Priced at pay band midpoints" : "Priced from the actual pay the plan holds, and at pay band midpoints for the rest"
    "For #{Views::Plans::ScenarioTable.figured(period)}, on #{on}. #{priced}. " \
      "Each line keeps its own currency; only the totals convert#{" to #{reference}" if reference}."
  end

  def scenario_budget
    totals
    lines_section
    unfunded_positions
    unpriced
    render Views::Plans::FundingDialog.new(scenario_id:, scenario_name: scenario_name(scenario_id), lines: @lines[:budget_lines]) if @can_edit
  end

  def totals
    total = @budget[:total]
    dl(class: "grid grid-cols-2 gap-3 lg:grid-cols-4", data: { budget_totals: "" }) do
      tile("Approved", total[:approved], head_count_text(total[:approved][:head_count]))
      tile("Funded", total[:funded], heads_text(total[:funded]))
      tile("Remaining", total[:remaining], head_count_text(total[:remaining][:head_count]), left_out: total[:remaining][:left_out], over: over?(total))
      tile("Unfunded", total[:unfunded], heads_text(total[:unfunded]))
    end
  end

  def tile(label, sum, heads, left_out: nil, over: false)
    div(class: "min-w-0 rounded-lg border border-default bg-default p-3", data: { budget_total: label.downcase }) do
      dt(class: "flex flex-wrap items-center gap-2 text-xs font-medium text-muted") do
        plain label
        render Components::Kit::Badge.new("Over", tone: :danger, data: { budget_over: "" }) if over
      end
      if money?
        dd(class: "mt-1 text-lg font-semibold text-default break-words") { Views::Plans::CostMarks::Format.sum(sum, reference) }
        dd(class: "text-xs text-muted") { heads } if heads
      else
        dd(class: "mt-1 text-lg font-semibold text-default break-words") { heads&.upcase_first || "No head count" }
      end
      left = left_out&.dig(:mismatched_currencies).to_a
      dd(class: "mt-1 text-xs text-warning", data: { budget_left_out: left.size }) { "Leaves out #{lines_count(left.size)} drawn on in another currency" } if left.any?
    end
  end

  def lines_section
    section(aria: { labelledby: "budget-lines-heading" }) do
      div(class: "flex flex-wrap items-center justify-between gap-2") do
        h4(id: "budget-lines-heading", class: "text-sm font-semibold text-default") { "Budget lines" }
        if @can_edit
          render Components::Kit::Button.new(variant: :outline, size: :sm, href: new_budget_line_plan_path(plan_id, scenario: scenario_id),
                                             id: "budget-line-add") { "Add a line" }
        end
      end
      if @budget[:budget_lines].empty?
        div(class: "mt-3") { render Components::Kit::EmptyState.new(title: "This scenario holds no budget lines.", size: :panel) }
      else
        ul(class: "mt-3 divide-y divide-default rounded-lg border border-default bg-default") { @budget[:budget_lines].each { line_row(it) } }
      end
    end
  end

  def line_row(line)
    id = line[:budget_line_id]
    described = described_lines[id]
    li(class: "space-y-2 p-3", data: { budget_line: id }) do
      div(class: "flex flex-wrap items-center gap-2") do
        p(class: "text-sm font-medium text-default break-words") { described ? line_name(described) : "A budget line" }
        render Components::Kit::Badge.new("Over", tone: :danger) if over?(line)
        if line[:mismatched_currencies].any?
          render Components::Kit::Badge.new("Drawn on in #{line[:mismatched_currencies].join(', ')}", tone: :warning, data: { budget_mismatch: "" })
        end
        change_link(id, described) if @can_edit && described
      end
      p(class: "text-xs text-muted break-words") { terms_text(described) } if described
      dl(class: "grid grid-cols-1 gap-1 text-sm sm:grid-cols-3") do
        if money?
          figure("Approved", line[:approved][:amount] ? money_text(line[:approved][:amount], line[:currency]) : "No amount", head_count_text(line[:approved][:head_count]))
          figure("Funded", natives(line[:funded][:native]), heads_text(line[:funded]))
          figure("Remaining", remaining_text(line), head_count_text(line[:remaining][:head_count]), data: { budget_remaining: "" })
        else
          figure("Approved", head_count_only(line[:approved][:head_count]), nil)
          figure("Funded", heads_text(line[:funded]).upcase_first, nil)
          figure("Remaining", head_count_only(line[:remaining][:head_count]), nil, data: { budget_remaining: "" })
        end
      end
      draws(line)
    end
  end

  def change_link(id, described)
    render Components::Kit::Button.new(variant: :link, tone: :brand, compact: true, class: "ml-auto",
                                       href: edit_budget_line_plan_path(plan_id, budget_line_id: id, scenario: scenario_id),
                                       aria_label: "Change #{line_name(described)}") { "Change" }
  end

  def funding_button(position_id, **)
    name = position_name(position_id)
    trigger = Views::Plans::FundingDialog.trigger(url: plan_funding_path(plan_id, position_id), name:, position: funding_by_position.fetch(position_id),
                                                   clearable: @funded_here.include?(position_id))
    render Components::Kit::Button.new(variant: :link, tone: :brand, compact: true, aria_label: "Change the funding of #{name}", data: trigger, **) { "Funding…" }
  end

  def figure(label, text, heads, data: {})
    div(class: "min-w-0", data:) do
      dt(class: "text-xs text-muted") { label }
      dd(class: "text-default break-words") do
        plain text
        span(class: "text-muted") { " · #{heads}" } if heads
      end
    end
  end

  def remaining_text(line)
    return money_text(line[:remaining][:amount], line[:currency]) if line[:remaining][:amount]
    return "Not worked out: its positions cost in another currency" if line[:mismatched_currencies].any?

    "No amount"
  end

  def draws(line)
    drawn = drawn_by_line.fetch(line[:budget_line_id], [])
    return if drawn.empty?

    short = drawn.select { unfunded_ids.include?(it[:position_id]) }
    details(open: over?(line) || short.any?, class: "text-sm", data: { budget_draws: "" }) do
      summary(class: "cursor-pointer text-muted hover:text-default") { "#{positions_count(drawn.size)} drawing on it" }
      ul(class: "mt-2 space-y-1") do
        drawn.each do |draw|
          li(class: "flex flex-wrap items-baseline gap-x-2", data: { budget_draw: draw[:position_id] }) do
            span(class: "text-default break-words") { position_name(draw[:position_id]) }
            span(class: "text-xs text-muted") { "#{DRAWS.fetch(draw[:draw_reason], draw[:draw_reason])} · #{share(draw[:share])} of it · #{decimal(draw[:fte])} FTE" }
            render Components::Kit::Badge.new("Partly unfunded", tone: :warning) if short.include?(draw)
            funding_button(draw[:position_id]) if @can_edit
          end
        end
      end
    end
  end

  def unfunded_positions
    positions = @funding[:positions].select { it[:state] == "unfunded" }
    section(aria: { labelledby: "budget-unfunded-heading" }) do
      h4(id: "budget-unfunded-heading", class: "text-sm font-semibold text-default") { "Unfunded positions" }
      if positions.empty?
        div(class: "mt-3") { render Components::Kit::EmptyState.new(title: "Every position draws on a budget line.", size: :panel) }
      else
        ul(class: "mt-3 divide-y divide-default rounded-lg border border-default bg-default") do
          positions.each do |position|
            li(class: "space-y-1 p-3", data: { budget_unfunded: position[:position_id] }) do
              div(class: "flex flex-wrap items-center gap-2") do
                p(class: "text-sm font-medium text-default break-words") { position_name(position[:position_id]) }
                funding_button(position[:position_id], class: "ml-auto") if @can_edit
              end
              p(class: "text-sm text-muted") { position[:reason_text] || "Part of it draws on no budget line" }
              tied(position[:matching_ids])
            end
          end
        end
      end
    end
  end

  def tied(ids)
    return if ids.blank?

    p(class: "text-xs text-muted break-words") { "Tied: #{ids.map { (described = described_lines[it]) ? line_name(described) : 'a removed line' }.join('; ')}" }
  end

  def unpriced
    return if @budget[:unpriced].empty?

    details(class: "text-sm", data: { budget_unpriced: "" }) do
      summary(class: "cursor-pointer text-muted hover:text-default") { "#{positions_count(@budget[:unpriced].size)} counted in head count with no money" }
      ul(class: "mt-2 space-y-1") do
        @budget[:unpriced].each do |position|
          li(class: "text-default break-words") { position_name(position[:position_id]) }
        end
      end
    end
  end

  # Over is the read's judgement under budget_strictness; nil where its scope doesn't hold this figure.
  def over?(figure) = (over = figure[:over]).present? && (over[:money].present? || over[:heads] == true)

  def funding_by_position = @funding_by_position ||= @funding[:positions].index_by { it[:position_id] }

  def described_lines = @described_lines ||= @lines[:budget_lines].index_by { it[:budget_line_id] }

  def drawn_by_line = @drawn_by_line ||= @funding[:budget_lines].to_h { [ it[:budget_line_id], it[:positions] ] }

  def unfunded_ids = @unfunded_ids ||= @funding[:positions].filter_map { it[:position_id] if it[:state] == "unfunded" }.to_set

  def position_name(id)
    name = position_names.fetch(id, "An open position")
    unit = unit_names[positions_by_id[id]&.dig(:unit_id)]
    unit ? "#{name} · #{unit}" : name
  end

  def position_names
    @position_names ||= Views::Plans::ScenarioMap.all_position_names(@map)
  end

  def positions_by_id = @positions_by_id ||= @map[:positions].index_by { it[:position_id] }

  def unit_names = @unit_names ||= @map[:units].to_h { [ it[:id], it[:name] ] }

  def natives(native) = Views::Plans::CostMarks::Format.sum({ native: }, nil).upcase_first

  def money_text(figure, currency) = Views::Plans::CostMarks::Format.amount(figure, currency)

  def heads_text(heads) = "#{positions_count(heads[:positions])}, #{decimal(heads[:fte])} FTE"

  def head_count_text(figure) = figure && "head count #{decimal(figure)}"

  def head_count_only(figure) = head_count_text(figure)&.upcase_first || "No head count"

  def positions_count(count) = "#{count} #{count == 1 ? 'position' : 'positions'}"

  def lines_count(count) = "#{count} #{count == 1 ? 'line' : 'lines'}"

  def share(figure) = "#{decimal(Views::Plans::FundingDialog.percent(figure))}%"

  def decimal(figure) = ActiveSupport::NumberHelper.number_to_rounded(BigDecimal(figure.to_s), precision: 2, strip_insignificant_zeros: true)
end
