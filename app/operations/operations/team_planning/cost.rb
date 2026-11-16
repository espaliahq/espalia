# frozen_string_literal: true

# What a scenario costs against the baseline, through {TeamPlanning::Cost}
# ([#288](https://github.com/espaliahq/espalia/issues/288)), or Today's
# yearly run rate when the scenario is the plan's own id
# ([#318](https://github.com/espaliahq/espalia/issues/318)). Totals come by
# default; a seat's working only for the one unit a caller names, so a large
# plan answers in a page. Figures leave as decimal strings. Band midpoints
# are tenant configuration, not anyone's pay, so every plan member sees them;
# each band's minimum and maximum need the see-pay right
# ([#300](https://github.com/espaliahq/espalia/issues/300)), as does any
# actual pay the plan holds
# ([#317](https://github.com/espaliahq/espalia/issues/317)). `pay_view` names
# which a caller got, each seat's `pay_source` how it was priced, and only a
# holder learns how many seats actual pay priced. It names people, so the forgotten-person audit walks it.
class Operations::TeamPlanning::Cost < Operations::Base
  include Operations::TeamPlanning::PlanRead
  include Operations::TeamPlanning::CostFigures

  description "Get what a scenario of a Team Planning plan the caller is in costs over its period, beside the baseline " \
              "priced over the same days, with the difference. Each seat (a person, or the FTE a position's occupants " \
              "leave open) is priced at the midpoint of its pay band: of the tenant's pay bands that match the seat's " \
              "role family, role, level number and location each band sets, or a framework level's level_id and location, the last in tenants_pay_bands order. The midpoint is made yearly (a month is 1/12, an hour takes the working_hours rule), scaled by FTE and by " \
              "the days it is held out of the year (365, or the run rate's own year: 366 across a 29 February), plus the on_cost rule of its unit. A person is priced at their own " \
              "level, a planned one winning, and at their position's level only when theirs resolves to none; " \
              "level_source says which. A leaver costs up to their leaving date and their backfill from the day after. " \
              "Totals are per currency in `native`, and `converted` is the same in the reference currency at the " \
              "period's start, null with `missing` saying why when a rate is missing. Units count their own places, " \
              "with null for no unit; `with_below` adds the units below. Cost centres use null for no cost centre. " \
              "A person keeps their own cost centre unless the plan changes their unit or the units above it, role, level or location " \
              "(an FTE change alone doesn't). A changed person, or a real person with none, takes their position's own cost centre, else the " \
              "last entry of the cost_centre rule at their unit that matches their planned unit, role or role family, level " \
              "number and location, else their own, else none. An open seat takes its position's own cost centre, else an " \
              "unchanged occupant's, else the last matching entry (it has no location), else none; a placeholder hire in a position " \
              "reads as that open seat. A seat's " \
              "cost_centre_source says which (position, person, rule or none); for a rule, cost_centre_rule is the " \
              "entry's index in the list that unit reads and cost_centre_matcher is what it matches on. " \
              "Unit, cost-centre and plan totals always agree. Every total carries `parts`, which add up to its " \
              "`scenario` figure exactly. In `parts`, actual means the baseline's figure, not actual pay: actual is the baseline's figure for the same unit or cost centre over the same days, " \
              "planned is what the plan's changes add or take away (negative where they take away, so someone moved between " \
              "units is negative in the old unit and positive in the new), and forecast is what the plan's forecast " \
              "assumptions add, zero until a forecast rule is set; team_planning_forecast lists its rows. A run rate is all actual. A seat that can't be priced is in `unpriced` with its reason, " \
              "never counted as zero. Pass unit_id for the working of each seat in that unit. Plans reprice live: " \
              "bands_changed_at says when a band last changed. Bands are an ordered list (tenants_pay_bands); each matches on the " \
              "role family, role, level number and location it sets, or on a framework level's level_id and location, and of the bands that match a seat the last in the list " \
              "has the last word. Each seat's band names its position in the list and its matcher. Pass the plan's id as scenario_id for Today's run rate: " \
              "basis is run_rate, period is the year from the base date to the day before the same date a year later, " \
              "each seat is priced for that whole year, and totals carry only `scenario`, with no baseline or difference, " \
              "as a run rate is never compared with a period total. A scenario has basis period. pay_view is band_ranges for a member with the see-pay " \
              "right, whose working shows each band's minimum and maximum, and band_midpoints for everyone else. " \
              "For a holder, a person whose actual pay the plan holds is priced from it instead (made yearly, scaled " \
              "by FTE only when its basis is full_time, by the days held, plus on-cost), in a run rate as in a scenario: each seat's pay_source " \
              "says actual or band_midpoint, and actual_pay_seats counts the seats priced from actual pay. Held pay " \
              "the plan lost with the person's key leaves the seat unpriced as pay_unknown. Everyone else is priced " \
              "at midpoints throughout, so the two views total differently. Figures are decimal strings; people are named by id in `names`. #{PRICED_TODAY} Refused, as an unknown " \
              "plan, unless the caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "A scenario of the plan, or the plan's id for Today's yearly run rate." }
  parameter :unit_id, String, allow_blank: false, schema: { description: "A unit on the scenario's or the baseline's map, for the working of each seat in it." }

  # @return [Hash] `{ plan_id, scenario_id, basis, period, reference_currency, bands_changed_at, pay_view, total,
  #   actual_pay_seats (for a see-pay holder),
  #   units, cost_centres, unpriced, names }`, and `seats` for a unit
  def perform
    plan = plan!
    scenario_id = scenario_id!(:scenario_id)
    report = refusing_bad_plans { ::TeamPlanning::Cost.new(context:, plan:, scenario_id:).call }
    @ranges = report.pay_view == "band_ranges"
    unit_id = unit!(report)
    unpriced = unpriced_lines(report)
    seats = { scenario: lines_in(report.scenario, unit_id), **({ baseline: lines_in(report.baseline, unit_id) } if report.baseline) } if unit_id
    { plan_id: plan.id, **priced_today(plan), scenario_id:, basis: report.basis, period: period(report),
      reference_currency: report.reference_currency, bands_changed_at: report.bands_changed_at&.iso8601,
      pay_view: report.pay_view, **actual_pay_seats(report),
      total: compared(report.parts, report), units: units(report), cost_centres: cost_centres(report),
      unpriced: unpriced.map { unpriced(it) }, **({ unit_id:, seats: } if unit_id), names: names(report, unpriced, seats) }
  end

  private

  def unit!(report)
    return nil if params[:unit_id].blank?

    unit_id = params[:unit_id].to_s.strip.downcase
    return unit_id if priced(report).any? { |priced| priced.map.units.any? { it.id == unit_id } }

    raise Operations::Base::ParameterError, "No such unit"
  end

  def actual_pay_seats(report)
    return {} unless @ranges

    { actual_pay_seats: { scenario: report.scenario.actual_pay_seats, **({ baseline: report.baseline.actual_pay_seats } if report.baseline) } }
  end

  def priced(report) = [ report.scenario, report.baseline ].compact

  def units(report)
    names = priced(report).reverse.flat_map { it.map.units }.to_h { [ it.id, it.name ] }
    ids = ([ *priced(report), report.forecast ].flat_map { it.units.keys }.uniq | names.keys)
    ids.sort_by { [ it.nil? ? 1 : 0, names[it].to_s, it.to_s ] }.map do |unit_id|
      row = { unit_id:, name: names[unit_id], **compared(report.parts(:units, unit_id), report) }
      next row unless unit_id

      row.merge(with_below: compared(report.parts(:units_with_below, unit_id), report))
    end
  end

  def cost_centres(report)
    [ *priced(report), report.forecast ].flat_map { it.cost_centres.keys }.uniq.sort_by { [ it.nil? ? 1 : 0, it.to_s ] }.map do |cost_centre|
      { cost_centre:, **compared(report.parts(:cost_centres, cost_centre), report) }
    end
  end

  def lines_in(priced, unit_id) = priced.lines.select { it.unit_id == unit_id }.map { line(it) }

  def line(line)
    band = line.band
    { seat_id: line.seat_id, kind: line.kind, position_id: line.position_id, cost_centre: line.cost_centre,
      cost_centre_source: line.cost_centre_source, cost_centre_rule: line.cost_centre_rule,
      cost_centre_matcher: line.cost_centre_matcher, level_id: line.level_id, level_source: line.level_source,
      pay_source: line.pay_source, basis: line.basis, currency: line.currency, band: band && band(band),
      hours_per_year: line.hours_per_year && decimal(line.hours_per_year), yearly: line.yearly && decimal(line.yearly),
      fte: decimal(line.fte), fraction: decimal(line.fraction),
      held: line.held && { starts_on: line.held.begin.iso8601, ends_on: line.held.end.iso8601 }, days: line.days,
      share: decimal(line.share), base: line.base && decimal(line.base),
      on_cost: line.on_cost && { amount: decimal(line.on_cost.amount), working: line.on_cost.working.map { { label: it.label, amount: decimal(it.amount) } } },
      amount: line.amount && decimal(line.amount), reason: line.reason, reason_text: ::TeamPlanning::Cost::REASONS[line.reason] }
  end

  def band(band)
    figures = @ranges ? PayBand::FIGURES : %i[midpoint]
    { pay_band_id: band.id, position: band.position, matcher: band.matcher_fields, level: band.level_label, location: band.location_name, currency: band.currency,
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
