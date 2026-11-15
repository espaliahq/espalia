# frozen_string_literal: true

# The scenario's cost above the map: its total over its period beside
# Today's over the same days, what is in no unit, and the seats no band
# prices ([#316](https://github.com/espaliahq/espalia/issues/316)).
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
        span(data: { cost_total: "" }, class: "text-lg font-semibold tabular-nums text-default") { Format.sum(total[:scenario], reference) }
        change
      end
      not_converted
      p(class: "text-sm text-muted") { basis }
      outside_units
      unpriced
    end
  end

  private

  def total = @marks.total

  def reference = @marks.reference

  def change
    text = Format.sum_change(total[:difference], reference)
    span(data: { cost_change: "" }, class: "text-sm tabular-nums #{text ? 'text-default' : 'text-muted'}") do
      text ? "#{text} vs Today" : "same as Today"
    end
  end

  def not_converted
    missing = total.values_at(:scenario, :baseline).reject { it[:converted] }.flat_map { it[:missing] }.uniq
    return if missing.empty?

    p(data: { cost_missing: "" }, class: "text-sm text-warning") do
      "Not totalled in one currency: #{missing.map { it.downcase_first.delete_suffix('.') }.to_sentence}."
    end
  end

  def basis
    period = @marks.cost[:period]
    changed = @marks.cost[:bands_changed_at]
    "For #{day(period[:starts_on])} to #{day(period[:ends_on])}, measured against Today over the same days, not against " \
      "the scenario this one follows. Priced at pay band midpoints, plus the on-cost rule at each unit" \
      "#{"; bands last changed #{Time.zone.parse(changed).strftime('%-d %b %Y')}" if changed}."
  end

  def outside_units
    row = @marks.outside_units
    return unless row

    p(data: { cost_outside: "" }, class: "text-sm text-muted") do
      "Of this, #{Format.sum(row[:scenario], reference)} is in no unit on the map: someone in no unit, or a place in a unit gone by this date."
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
