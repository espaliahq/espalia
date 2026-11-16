# frozen_string_literal: true

# The scenario's cost above the map: its total over its period beside
# Today's over the same days, what is in no unit, and the seats no band
# prices ([#316](https://github.com/espaliahq/espalia/issues/316)). On
# Today's map it is the yearly run rate instead, with nothing beside it
# ([#318](https://github.com/espaliahq/espalia/issues/318)).
class Views::Plans::CostStrip < Views::Base
  Format = Views::Plans::CostMarks::Format

  # @param marks [Views::Plans::CostMarks]
  def initialize(marks:)
    @marks = marks
  end

  def view_template
    section(aria: { labelledby: "cost-strip" }, data: { cost_strip: "" },
            class: "rounded-lg border border-default bg-default px-4 py-3 space-y-2") do
      div(class: "flex flex-wrap items-baseline gap-x-3 gap-y-1") do
        h3(id: "cost-strip", class: "text-sm font-semibold text-default") { "Cost" }
        span(data: { cost_total: "" }, class: "text-lg font-semibold tabular-nums text-default") { figure }
        @marks.run_rate? ? span(data: { cost_run_rate: "" }, class: "text-sm text-muted") { "yearly run rate" } : change_and_parts
      end
      not_converted
      p(class: "text-sm text-muted") { basis }
      outside_units
      unpriced
    end
  end

  private

  def total = @marks.total

  def figure = figure_of(total[:scenario])

  def figure_of(sum)
    text = Format.sum(sum, reference)
    @marks.run_rate? ? Format.yearly(text) : text
  end

  def reference = @marks.reference

  def change_and_parts
    text = Format.sum_change(total[:difference], reference)
    span(data: { cost_change: "" }, class: "text-sm tabular-nums #{text ? 'text-default' : 'text-muted'}") do
      text ? "#{text} vs Today" : "same as Today"
    end
    render Views::Plans::FigureParts.new(parts: Format.parts(total[:parts], reference))
  end

  def not_converted
    missing = total.values_at(:scenario, :baseline).compact.reject { it[:converted] }.flat_map { it[:missing] }.uniq
    return if missing.empty?

    p(data: { cost_missing: "" }, class: "text-sm text-warning") do
      "Not totalled in one currency: #{missing.map { it.downcase_first.delete_suffix('.') }.to_sentence}."
    end
  end

  def basis
    period = @marks.cost[:period]
    changed = @marks.cost[:bands_changed_at]
    return run_rate_basis(period, changed) if @marks.run_rate?

    "For #{day(period[:starts_on])} to #{day(period[:ends_on])}, measured against Today over the same days, not against " \
      "the scenario this one follows. #{priced_from}, plus the on-cost rule at each unit" \
      "#{"; bands last changed #{Time.zone.parse(changed).strftime('%-d %b %Y')}" if changed}."
  end

  def run_rate_basis(period, changed)
    "What Today costs in a year: every seat it holds priced for #{day(period[:starts_on])} to #{day(period[:ends_on])}. " \
      "A run rate, not a period total, so it is never set against a scenario's cost. #{priced_from(scenario: nil)}, plus " \
      "the on-cost rule at each unit#{"; bands last changed #{Time.zone.parse(changed).strftime('%-d %b %Y')}" if changed}."
  end

  # Only a member with the see-pay right gets a count of seats priced from actual pay.
  def priced_from(places = { scenario: "here", baseline: "in Today" })
    held = @marks.cost[:actual_pay_seats]
    return "Priced at pay band midpoints" unless held && held.values.any? { it.to_i.positive? }

    where = places.filter_map { |side, place| [ seats(held[side]), place ].compact.join(" ") if held[side].to_i.positive? }
    "Priced from the actual pay the plan holds for #{where.join(' and ')}, and at pay band midpoints for the rest"
  end

  def seats(count) = "#{count} #{count == 1 ? 'seat' : 'seats'}"

  def outside_units
    row = @marks.outside_units
    return unless row

    p(data: { cost_outside: "" }, class: "text-sm text-muted") do
      "Of this, #{figure_of(row[:scenario])} is in no unit on the map: someone in no unit, or a place in a unit gone by this date."
    end
  end

  def unpriced
    seats = @marks.unpriced
    return if seats.empty?

    details(data: { cost_unpriced: "" }, class: "text-sm") do
      summary(class: "text-default underline") do
        "#{seats.size} #{seats.size == 1 ? 'seat has' : 'seats have'} no price and #{seats.size == 1 ? 'is' : 'are'} left out"
      end
      ul(class: "mt-1 list-disc pl-5 text-muted") do
        seats.each { |seat| li { "#{seat[:name]}: #{seat[:reason].downcase_first}" } }
      end
    end
  end

  def day(iso) = Date.iso8601(iso).strftime("%-d %b %Y")
end
