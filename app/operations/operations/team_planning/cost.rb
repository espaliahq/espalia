# frozen_string_literal: true

# What a scenario costs against the baseline, through {TeamPlanning::Cost}
# ([#288](https://github.com/espaliahq/espalia/issues/288)), or Today's
# yearly run rate when the scenario is the plan's own id
# ([#318](https://github.com/espaliahq/espalia/issues/318)). Totals come by
# default; a seat's working only for the one unit a caller names, so a large
# plan answers in a page. Figures leave as decimal strings. Band midpoints
# are tenant configuration, not anyone's pay, so every plan member sees them;
# each band's minimum and maximum need the see-pay right
# ([#300](https://github.com/espaliahq/espalia/issues/300)), and `pay_view`
# names which a caller got. It names people, so the forgotten-person audit
# walks it.
class Operations::TeamPlanning::Cost < Operations::Base
  include Operations::TeamPlanning::PlanRead
  include Operations::TeamPlanning::CostFigures

  description "Get what a scenario of a Team Planning plan the caller is in costs over its period, beside the baseline " \
              "priced over the same days, with the difference. Each seat (a person, or the FTE a position's occupants " \
              "leave open) is priced at the midpoint of the pay band for its level and country (else the band for any " \
              "location), made yearly (a month is 1/12, an hour takes the working_hours rule), scaled by FTE and by " \
              "the days it is held out of the year (365, or the run rate's own year: 366 across a 29 February), plus the on_cost rule of its unit. A person is priced at their own " \
              "level, a planned one winning, and at their position's level only when theirs resolves to none; " \
              "level_source says which. A leaver costs up to their leaving date and their backfill from the day after. " \
              "Totals are per currency in `native`, and `converted` is the same in the reference currency at the " \
              "period's start, null with `missing` saying why when a rate is missing. Units count their own places, " \
              "with null for no unit; `with_below` adds the units below. Cost centres use null for no cost centre. " \
              "A person's seat takes the person's cost centre. A placeholder hire's seat and an open seat take their position's own " \
              "cost centre, else its occupant's, else the first cost_centre rule at its unit that matches; a seat's " \
              "cost_centre_source says which (position, person, rule or none), and cost_centre_rule is the " \
              "winning rule's index in the cost_centre list that unit reads. " \
              "Unit, cost-centre and plan totals always agree. A seat that can't be priced is in `unpriced` with its reason, " \
              "never counted as zero. Pass unit_id for the working of each seat in that unit. Plans reprice live: " \
              "bands_changed_at says when a band last changed. Pass the plan's id as scenario_id for Today's run rate: " \
              "basis is run_rate, period is the year from the base date to the day before the same date a year later, " \
              "each seat is priced for that whole year, and totals carry only `scenario`, with no baseline or difference, " \
              "as a run rate is never compared with a period total. A scenario has basis period. pay_view is band_ranges for a member with the see-pay " \
              "right, whose seat working also shows each band's minimum and maximum, and band_midpoints for " \
              "everyone else. Totals are the same in both. Figures are decimal strings; people are named by id in `names`. Refused, as an unknown " \
              "plan, unless the caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "A scenario of the plan, or the plan's id for Today's yearly run rate." }
  parameter :unit_id, String, allow_blank: false, schema: { description: "A unit on the scenario's or the baseline's map, for the working of each seat in it." }

  # @return [Hash] `{ plan_id, scenario_id, basis, period, reference_currency, bands_changed_at, pay_view, total,
  #   units, cost_centres, unpriced, names }`, and `seats` for a unit
  def perform
    plan = plan!
    @ranges = PlanPolicy.new(context, plan).see_pay?
    scenario_id = scenario_id!(:scenario_id)
    report = refusing_bad_plans { ::TeamPlanning::Cost.new(context:, plan:, scenario_id:).call }
    unit_id = unit!(report)
    unpriced = unpriced_lines(report)
    seats = { scenario: lines_in(report.scenario, unit_id), **({ baseline: lines_in(report.baseline, unit_id) } if report.baseline) } if unit_id
    { plan_id: plan.id, scenario_id:, basis: report.basis, period: period(report),
      reference_currency: report.reference_currency, bands_changed_at: report.bands_changed_at&.iso8601,
      pay_view: @ranges ? "band_ranges" : "band_midpoints",
      total: compared(report, report.scenario.total, report.baseline&.total), units: units(report), cost_centres: cost_centres(report),
      unpriced: unpriced.map { unpriced(it) }, **({ unit_id:, seats: } if unit_id), names: names(report, unpriced, seats) }
  end

  private

  def unit!(report)
    return nil if params[:unit_id].blank?

    unit_id = params[:unit_id].to_s.strip.downcase
    return unit_id if priced(report).any? { |priced| priced.map.units.any? { it.id == unit_id } }

    raise Operations::Base::ParameterError, "No such unit"
  end

  def priced(report) = [ report.scenario, report.baseline ].compact

  def units(report)
    names = priced(report).reverse.flat_map { it.map.units }.to_h { [ it.id, it.name ] }
    ids = (priced(report).flat_map { it.units.keys }.uniq | names.keys)
    ids.sort_by { [ it.nil? ? 1 : 0, names[it].to_s, it.to_s ] }.map do |unit_id|
      row = { unit_id:, name: names[unit_id], **compared(report, report.scenario.units[unit_id], report.baseline&.units&.[](unit_id)) }
      next row unless unit_id

      row.merge(with_below: compared(report, report.scenario.units_with_below[unit_id], report.baseline&.units_with_below&.[](unit_id)))
    end
  end

  def cost_centres(report)
    priced(report).flat_map { it.cost_centres.keys }.uniq.sort_by { [ it.nil? ? 1 : 0, it.to_s ] }.map do |cost_centre|
      { cost_centre:, **compared(report, report.scenario.cost_centres[cost_centre], report.baseline&.cost_centres&.[](cost_centre)) }
    end
  end

  def lines_in(priced, unit_id) = priced.lines.select { it.unit_id == unit_id }.map { line(it) }

  def line(line)
    band = line.band
    { seat_id: line.seat_id, kind: line.kind, position_id: line.position_id, cost_centre: line.cost_centre,
      cost_centre_source: line.cost_centre_source, cost_centre_rule: line.cost_centre_rule, level_id: line.level_id, level_source: line.level_source,
      band: band && band(band),
      hours_per_year: line.hours_per_year && decimal(line.hours_per_year), yearly: line.yearly && decimal(line.yearly),
      fte: decimal(line.fte), fraction: decimal(line.fraction),
      held: line.held && { starts_on: line.held.begin.iso8601, ends_on: line.held.end.iso8601 }, days: line.days,
      share: decimal(line.share), base: line.base && decimal(line.base),
      on_cost: line.on_cost && { amount: decimal(line.on_cost.amount), working: line.on_cost.working.map { { label: it.label, amount: decimal(it.amount) } } },
      amount: line.amount && decimal(line.amount), reason: line.reason, reason_text: ::TeamPlanning::Cost::REASONS[line.reason] }
  end

  def band(band)
    figures = @ranges ? PayBand::FIGURES : %i[midpoint]
    { pay_band_id: band.id, level: band.level_label, location: band.location_name, currency: band.currency,
      period: band.period, **figures.index_with { band.figure(it) } }
  end

  def unpriced(line)
    { seat_id: line.seat_id, kind: line.kind, unit_id: line.unit_id, level_id: line.level_id, reason: line.reason,
      reason_text: ::TeamPlanning::Cost::REASONS.fetch(line.reason) }
  end

  def names(report, unpriced, seats)
    ids = (unpriced.map { [ it.kind, it.seat_id ] } + seats.to_h.values.flatten.map { [ it[:kind], it[:seat_id] ] })
          .filter_map { |kind, id| id if kind == "person" }.uniq
    in_scenario = report.scenario.map.people.to_set(&:id)
    ids.to_h { [ it, (in_scenario.include?(it) || !report.baseline ? report.scenario.map : report.baseline.map).name_of(it) ] }
  end
end
