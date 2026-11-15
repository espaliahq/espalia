# frozen_string_literal: true

# How the cost reads send money: each sum per currency and converted, as
# decimal strings, so no figure rounds before the screen draws it.
module Operations::TeamPlanning::CostFigures
  SIGNIFICANT_DIGITS = 20

  private

  def compared(report, scenario, baseline)
    scenario ||= ::TeamPlanning::Cost.nothing(report.reference_currency)
    return { scenario: sum(scenario) } if report.run_rate?

    baseline ||= ::TeamPlanning::Cost.nothing(report.reference_currency)
    { scenario: sum(scenario), baseline: sum(baseline), difference: sum(::TeamPlanning::Cost.difference(scenario, baseline)) }
  end

  def unpriced_lines(report) = [ report.scenario, report.baseline ].compact.flat_map(&:unpriced).uniq { [ it.seat_id, it.unit_id, it.reason ] }

  def period(report) = { starts_on: report.period.begin.iso8601, ends_on: report.period.end.iso8601 }

  def sum(sum) = { native: sum.native.transform_values { decimal(it) }, converted: sum.converted && decimal(sum.converted), missing: sum.missing }

  def decimal(value) = BigDecimal(value, SIGNIFICANT_DIGITS).to_s("F").delete_suffix(".0")
end
