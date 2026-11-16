# frozen_string_literal: true

# The quiet lines under each step of the timeline
# ([#452](https://github.com/espaliahq/espalia/issues/452)): what the step
# costs, what of its budget is unfunded, and what it can deliver, from
# `team_planning_timeline_figures`. It draws those figures and works none out.
#
# The timeline draws it twice as a lazy frame, before any figure arrives: a
# row of cells on a wide screen, one per step under its header, and a line in
# the phone's step card. Each loads only once it is in sight, so a viewport
# fetches its own. A member without the see-pay right gets band midpoints and
# head counts, and no budget money.
class Views::Plans::TimelineFigures < Views::Base
  WIDE_ID = "timeline-figures"
  PHONE_ID = "timeline-figures-phone"
  LOADING = "Loading figures…"

  # @param figures [Hash, nil] from `team_planning_timeline_figures`; nil for the placeholder
  # @param scenarios [Array<Hash>] from `team_planning_scenarios`, for each step's name
  # @param phone [Boolean] the phone's one step, rather than a cell per step
  # @param step [Integer] the step a phone shows, from the left
  # @param src [String, nil] the frame's own path, for the placeholder
  def initialize(figures: nil, scenarios: [], phone: false, step: 0, src: nil)
    @figures = figures
    @names = scenarios.to_h { [ it[:scenario_id], it[:name] ] }
    @phone = phone
    @step = step
    @src = src
  end

  def view_template
    @phone ? phone : wide
  end

  private

  def wide
    turbo_frame_tag(WIDE_ID, src: @src, loading: ("lazy" if @src), class: "grid",
                             style: "grid-column: 1 / -1; grid-template-columns: subgrid", data: { frame_error_target: "frame" }) do
      if @figures
        @figures[:steps].each_with_index do |step, index|
          div(class: "min-w-0 border-l border-default px-3 pb-2", style: "grid-column: #{index + 1}", data: { timeline_figures: index }) do
            lines(step, label: "Figures for #{step_name(step)}")
          end
        end
      else
        loading(class: "border-l border-default px-3 pb-2", style: "grid-column: 1 / -1")
      end
    end
  end

  def phone
    turbo_frame_tag(PHONE_ID, src: @src, loading: ("lazy" if @src), class: "mt-1 block",
                              data: { frame_error_target: "frame" }) do
      step = @figures && @figures[:steps][@step.clamp(0, @figures[:steps].size - 1)]
      step ? div(data: { timeline_figures: @step }) { lines(step) } : loading
    end
  end

  def loading(**attrs) = p(class: "text-xs text-muted #{attrs.delete(:class)}", aria: { busy: "true" }, **attrs) { LOADING }

  def lines(step, label: nil)
    span(class: "sr-only") { "#{label}: " } if label
    line(:cost) { plain [ cost(step), (unpriced(step[:unpriced]) if step[:unpriced].positive?) ].compact.join(" · ").presence || "No cost" }
    budget(step[:budget]) if step[:budget]
    line(:capacity) { capacity(step[:capacity]) } if step[:capacity].any?
  end

  def line(kind, &) = p(class: "text-xs text-muted break-words", data: { timeline_figure: kind }, &)

  # Nothing priced says so once, through the unpriced count, rather than as "nothing a year".
  def cost(step)
    return if step[:cost][:native].empty?

    money = Views::Plans::CostMarks::Format.sum(step[:cost], reference)
    return "#{money} a year" if step[:basis] == "run_rate"

    step.dig(:period, :open_ended) ? "#{money} over the #{step.dig(:period, :horizon_months)} months shown" : "#{money} over the step"
  end

  # Without the see-pay right a budget has head counts and no money.
  def budget(budget)
    unfunded = budget[:unfunded]
    line(:budget) do
      if @figures[:money]
        plain money_line(budget[:approved], unfunded)
      else
        plain(unfunded[:positions].zero? ? "All positions funded" : "#{positions(unfunded[:positions])} unfunded")
      end
      span(class: "font-medium text-warning") { " · over" } if over?(budget[:over])
    end
  end

  def money_line(approved, unfunded)
    funded = zero?(unfunded) ? "all funded" : "#{Views::Plans::CostMarks::Format.sum(unfunded, reference)} unfunded"
    return "Budget #{Views::Plans::CostMarks::Format.sum(approved, reference)} · #{funded}" if approved[:native].any?

    zero?(unfunded) ? "No budget" : "No budget · #{funded}"
  end

  def capacity(capacity)
    plain(capacity.map { |model, amount| Views::Plans::CapacityMarks::Format.amount(BigDecimal(amount), symbol(model)) }.join(" · "))
  end

  def over?(over) = over.present? && (over[:money].present? || over[:heads])

  def zero?(sum) = sum[:converted] ? BigDecimal(sum[:converted]).round.zero? : sum[:native].values.all? { BigDecimal(it).round.zero? }

  def symbol(model) = TeamPlanning::CapacityModels.registered?(model) ? TeamPlanning::CapacityModels.fetch(model).symbol : model

  def unpriced(count) = "#{count} #{'seat'.pluralize(count)} unpriced"

  def positions(count) = "#{count} #{'position'.pluralize(count)}"

  def reference = @figures[:reference_currency]

  def step_name(step)
    step[:scenario_id] == @figures[:plan_id] ? "Today" : @names[step[:scenario_id]].presence || Views::Plans::Timeline::UNNAMED
  end
end
