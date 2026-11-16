# frozen_string_literal: true

# What a scenario can deliver, through {TeamPlanning::Capacity}
# ([#255](https://github.com/espaliahq/espalia/issues/255)). Figures leave as
# decimal strings, so a client never rounds a third before it sums. It names
# people, so the forgotten-person audit walks it.
class Operations::TeamPlanning::Capacity < Operations::Base
  include Operations::TeamPlanning::PlanRead

  SIGNIFICANT_DIGITS = 20

  description "Get the capacity of a scenario of a Team Planning plan the caller is in. Each person is a seat, and " \
              "so is each position for the FTE its occupants leave open. Each place a seat holds (a unit or a " \
              "position, and its share of the seat) is priced by the capacity model its role chooses through the " \
              "capacity_model planning rule, a role's choice beating its family's. A place in a position takes the " \
              "position's role and level; a person placed straight in a unit takes those their title and level map " \
              "to. An allocation the HRIS didn't give (allocation_known false) shares what the seat's other places " \
              "leave. Each figure carries its working. Totals are per model, per unit and for the scenario, never " \
              "summed across models; a place in a unit gone from the map counts for the scenario only. A place no " \
              "model covers counts nowhere and is listed in `unclassified` with its reason. Each working step has " \
              "an op (+, × or =) and, where it charges for someone or an open seat, a subject_id. A figure is " \
              "overloaded when what the seat costs to manage beats its base, by `excess`, and its notes say what a " \
              "reader should know, such as an open seat that counts against no manager. A planner's override " \
              "(team_planning_set_capacity_override) replaces a place's capacity, its working ends with the override, " \
              "and `calculated` carries the model's figure, with that figure's overloaded, excess and notes in " \
              "`calculated_diagnostics` while the top-level ones describe the planner's figure. An override the " \
              "plan can't read, since its person was forgotten, leaves the place unclassified with the model's " \
              "figure still in `calculated`. `overridden` marks every place the plan holds an override for, so one " \
              "on a place that counts nowhere for another reason, such as a leaver's, stays visible. Figures are " \
              "decimal strings. Each total carries `parts`, which add up to it per model: actual is the baseline's capacity (the baseline's figure, not actual pay), " \
              "planned is what the plan's changes add or take away (negative where they take away, so someone moved between " \
              "units is negative in the old unit and positive in the new), and forecast is what the plan's forecast " \
              "assumptions add, zero until a forecast rule is set. The baseline is all actual. `units` lists each unit " \
              "on the scenario's map that counts in any part, so a unit everyone left still shows its negative planned; " \
              "a unit gone from the scenario's map counts in the scenario's parts only. `models` maps each model a place or a figure uses to its symbol, what follows its figures on " \
              "screen, and its description. People are named by id, and `names` maps each to a name. #{PRICED_TODAY} Refused, as an unknown plan, " \
              "unless the caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "The scenario, or the plan's id for the baseline." }

  # @return [Hash] `{ plan_id, scenario_id, totals, parts, units, seats, unclassified, models, names }`
  def perform
    plan = plan!
    scenario_id = scenario_id!(:scenario_id)
    split = refusing_bad_plans { ::TeamPlanning::Capacity.split(context:, plan:, scenario_id:) }
    report = split.report
    { plan_id: plan.id, **priced_today(plan), scenario_id:, **totals(split.parts), units: units(split),
      seats: report.seats.map { seat(it) }, unclassified: report.unclassified.map { |seat, place| unclassified(seat, place) },
      models: models(split), names: names(report) }
  end

  private

  def models(split)
    parts = split.parts
    used = (split.report.seats.flat_map { |seat| seat.places.filter_map(&:model) } + [ parts.actual, parts.planned, parts.forecast ].flat_map(&:keys))
           .uniq.select { ::TeamPlanning::CapacityModels.registered?(it) }.sort
    used.to_h { |name| model = ::TeamPlanning::CapacityModels.fetch(name); [ name, { symbol: model.symbol, description: model.description } ] }
  end

  def names(report)
    people = report.map.people.to_set(&:id)
    subjects = report.seats.flat_map { |seat| seat.places.flat_map { it.figure&.working.to_a.map(&:subject_id) } }
    (report.seats.select { it.seat.kind == "person" }.map { it.seat.id } + subjects.select { people.include?(it) })
      .uniq.to_h { [ it, report.map.name_of(it) ] }
  end

  def units(split)
    counted = [ *split.report.units.keys, *split.baseline&.units&.keys, *split.forecast.map(&:unit_id) ].to_set
    split.report.map.units.select { counted.include?(it.id) }.map { |unit| { unit_id: unit.id, name: unit.name, **totals(split.parts(unit.id)) } }
  end

  def totals(parts)
    { totals: figures(parts.total), parts: { actual: figures(parts.actual), planned: figures(parts.planned), forecast: figures(parts.forecast) } }
  end

  def seat(priced)
    seat = priced.seat
    { seat_id: seat.id, kind: seat.kind, fte: decimal(seat.fte), fte_known: seat.fte_known, places: priced.places.map { place(it) } }
  end

  def place(priced)
    place = priced.place
    { unit_id: place.unit_id, position_id: place.position_id, allocation: decimal(place.allocation),
      allocation_known: place.allocation_known, role_id: place.role_id, level_id: place.level_id,
      model: priced.model, chosen_for: priced.chosen_for, capacity: priced.figure && decimal(priced.figure.amount),
      calculated: priced.calculated && decimal(priced.calculated.amount), overridden: priced.overridden,
      calculated_diagnostics: priced.calculated && diagnostics(priced.calculated, priced.model), **figure(priced), reason: priced.reason, reason_text: ::TeamPlanning::Capacity::REASONS[priced.reason] }
  end

  def figure(priced)
    figure = priced.figure
    return { working: nil, overloaded: nil, excess: nil, notes: [] } unless figure

    { working: figure.working.map { { label: it.label, amount: decimal(it.amount), op: it.op, subject_id: it.subject_id } },
      **diagnostics(figure, priced.model) }
  end

  def diagnostics(figure, model)
    texts = ::TeamPlanning::CapacityModels.fetch(model).notes
    { overloaded: figure.overloaded, excess: decimal(figure.excess), notes: figure.notes.map { { note: it, text: texts[it] } } }
  end

  def unclassified(seat, place)
    { seat_id: seat.seat.id, kind: seat.seat.kind, unit_id: place.unit_id, allocation: decimal(place.place.allocation),
      overridden: place.overridden, reason: place.reason,
      reason_text: ::TeamPlanning::Capacity::REASONS.fetch(place.reason) }
  end

  def figures(totals) = totals.transform_values { decimal(it) }

  def decimal(value) = BigDecimal(value, SIGNIFICANT_DIGITS).to_s("F").delete_suffix(".0")
end
