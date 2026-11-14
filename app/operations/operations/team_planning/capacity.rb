# frozen_string_literal: true

# What a scenario can deliver, through {TeamPlanning::Capacity}
# ([#255](https://github.com/espaliahq/espalia/issues/255)). Figures leave as
# decimal strings, so a client never rounds a third before it sums. It names
# people, so the forgotten-person audit walks it.
class Operations::TeamPlanning::Capacity < Operations::Base
  include Operations::TeamPlanning::PlanRead

  SIGNIFICANT_DIGITS = 20

  description "Get the capacity of a scenario of a Team Planning plan the caller is in. Each person and open " \
              "position is a seat; each place it holds (a unit and its share of the seat) is priced by the " \
              "capacity model its role chooses, through the capacity_model planning rule (a role's choice beats " \
              "its family's). A person's role and level come from their title and level on the map; a " \
              "position's from the position. Each figure carries its working. Totals are per model, per unit " \
              "and for the scenario, never summed across models. A place no model covers counts nowhere and is " \
              "listed in `unclassified` with its reason. Figures are decimal strings. People are named by id, " \
              "and `names` maps each to a name. Refused, as an unknown plan, unless the caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true
  parameter :scenario_id, String, required: true, schema: { description: "The scenario, or the plan's id for the baseline." }

  # @return [Hash] `{ plan_id, scenario_id, totals, units, seats, unclassified, names }`
  def perform
    plan = plan!
    scenario_id = scenario_id!(:scenario_id)
    report = refusing_bad_plans { ::TeamPlanning::Capacity.new(context:, plan:, scenario_id:).call }
    { plan_id: plan.id, scenario_id:, totals: figures(report.totals), units: units(report),
      seats: report.seats.map { seat(it) }, unclassified: report.unclassified.map { |seat, place| unclassified(seat, place) },
      names: report.seats.select { it.seat.kind == "person" }.to_h { [ it.seat.id, report.map.name_of(it.seat.id) ] } }
  end

  private

  def units(report)
    names = report.map.units.to_h { [ it.id, it.name ] }
    report.units.map { |unit_id, totals| { unit_id:, name: names[unit_id], totals: figures(totals) } }
  end

  def seat(priced)
    seat = priced.seat
    { seat_id: seat.id, kind: seat.kind, fte: decimal(seat.fte), fte_known: seat.fte_known, places: priced.places.map { place(it) } }
  end

  def place(priced)
    { unit_id: priced.unit_id, allocation: priced.place && decimal(priced.place.allocation),
      role_id: priced.place&.role_id, level_id: priced.place&.level_id, model: priced.model, chosen_for: priced.chosen_for,
      capacity: priced.figure && decimal(priced.figure.amount),
      working: priced.figure&.working&.map { { label: it.label, amount: decimal(it.amount) } },
      reason: priced.reason, reason_text: ::TeamPlanning::Capacity::REASONS[priced.reason] }
  end

  def unclassified(seat, place)
    { seat_id: seat.seat.id, kind: seat.seat.kind, unit_id: place.unit_id, reason: place.reason,
      reason_text: ::TeamPlanning::Capacity::REASONS.fetch(place.reason) }
  end

  def figures(totals) = totals.transform_values { decimal(it) }

  def decimal(value) = BigDecimal(value, SIGNIFICANT_DIGITS).to_s("F").delete_suffix(".0")
end
