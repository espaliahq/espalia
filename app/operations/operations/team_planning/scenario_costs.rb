# frozen_string_literal: true

# Every scenario's total against the baseline, for the plan page's Cost
# column ([#316](https://github.com/espaliahq/espalia/issues/316)), after
# Today's yearly run rate ([#318](https://github.com/espaliahq/espalia/issues/318)). It reads
# the Org Graph once for the whole plan, where calling `team_planning_cost`
# per scenario would read it once each. Totals only: no seat, band or
# person, so the see-pay right changes nothing in it.
class Operations::TeamPlanning::ScenarioCosts < Operations::Base
  include Operations::TeamPlanning::PlanRead
  include Operations::TeamPlanning::CostFigures

  description "Get what each scenario of a Team Planning plan the caller is in costs over its own period, beside " \
              "the baseline priced over the same days, with the difference: the same totals as team_planning_cost, " \
              "for every scenario at once. Today comes first, under the plan's id, with basis run_rate: every seat priced " \
              "for the year from the base date, totals carrying only `scenario`, never compared with a period total. " \
              "Each scenario has basis period. Totals are per currency " \
              "in `native`, and `converted` is the same in the reference currency at each period's start, null with " \
              "`missing` saying why. `unpriced` counts the seats that can't be priced and so are left out, never " \
              "counted as zero; team_planning_cost names them. A scenario that can't be priced has `error` instead " \
              "of figures. Figures are decimal strings. Refused, as an unknown plan, unless the caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true

  # @return [Hash] `{ plan_id, reference_currency, bands_changed_at, scenarios: [{ scenario_id, basis, period, total, unpriced }
  #   or { scenario_id, error }] }`
  def perform
    plan = plan!
    reports = ::TeamPlanning::Cost.every_scenario(context:, plan:)
    priced = reports.values.grep(::TeamPlanning::Cost::Report)
    { plan_id: plan.id, reference_currency: ReferenceCurrency.where(tenant_id: plan.tenant_id).first&.currency,
      bands_changed_at: priced.filter_map(&:bands_changed_at).max&.iso8601,
      scenarios: reports.map { |scenario_id, report| scenario(scenario_id, report) } }
  end

  private

  def scenario(scenario_id, report)
    return { scenario_id:, error: report.message } unless report.is_a?(::TeamPlanning::Cost::Report)

    { scenario_id:, basis: report.basis, period: period(report),
      total: compared(report, report.scenario.total, report.baseline&.total), unpriced: unpriced_lines(report).size }
  end
end
