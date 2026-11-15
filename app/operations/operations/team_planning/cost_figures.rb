# frozen_string_literal: true

# How the cost reads send money: each sum per currency and converted, as
# decimal strings, so no figure rounds before the screen draws it.
module Operations::TeamPlanning::CostFigures
  SIGNIFICANT_DIGITS = 20

  private

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
