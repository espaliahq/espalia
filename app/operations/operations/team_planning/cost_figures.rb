# frozen_string_literal: true

# How the cost reads send money: each sum per currency and converted, as
# decimal strings, so no figure rounds before the screen draws it.
module Operations::TeamPlanning::CostFigures
  SIGNIFICANT_DIGITS = 20
  RUN_RATE_AT_END = "A scenario also has run_rate_at_end: every seat it holds on its last day (`on`), each priced for a full " \
                    "year and converted at that day's rates, beside the baseline's seats priced the same way, so a move in " \
                    "exchange rates is never a planned change. Its difference is on Today's run rate. Its parts: actual is " \
                    "the baseline on that day, planned what the plan's changes add or take away, and forecast a year of " \
                    "each forecast row's headcount still changed that day, at the row's average cost (for attrition, the " \
                    "steady share of seats waiting to be filled). Today has none, as it is a run rate already."

  private

  def at_end_total(report) = { on: report.at_end.on.iso8601, total: compared(report.at_end_parts, report) }

  # The total, beside the baseline with the difference unless it is a run
  # rate, and its parts: actual, planned and forecast, which add up to it.
  def compared(parts, report)
    split = { actual: sum(parts.actual), planned: sum(parts.planned), forecast: sum(parts.forecast) }
    return { scenario: sum(parts.total), parts: split } if report.run_rate?

    { scenario: sum(parts.total), baseline: sum(parts.actual), difference: sum(::TeamPlanning::Cost.difference(parts.total, parts.actual)), parts: split }
  end

  def unpriced_lines(report) = [ report.scenario, report.baseline ].compact.flat_map(&:unpriced).uniq { [ it.seat_id, it.unit_id, it.reason ] }

  def period(report) = { starts_on: report.period.begin.iso8601, ends_on: report.period.end.iso8601 }

  def sum(sum) = { native: sum.native.transform_values { decimal(it) }, converted: sum.converted && decimal(sum.converted), missing: sum.missing }

  def decimal(value) = BigDecimal(value, SIGNIFICANT_DIGITS).to_s("F").delete_suffix(".0")
end
